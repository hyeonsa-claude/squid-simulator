#!/usr/bin/env bash
# Runs the simulator against tests/ and compares the results with tests/expected-*.txt.
# Usage: scripts/test.sh [path/to/patched/squid]
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SQUID=${1:-$(ls -d "$ROOT"/build/squid-*/src/squid 2>/dev/null | head -1)}
T="$ROOT/tests"
OUT=$(mktemp -d)
FAILED=0

if [ -z "$SQUID" ] || [ ! -x "$SQUID" ]; then
    echo "patched squid binary not found; run scripts/build.sh first or pass its path" >&2
    exit 2
fi
echo "squid: $SQUID ($("$SQUID" -v | head -1))"

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# 1. the patched binary still parses a config like stock squid
echo "[parse] squid -k parse"
if "$SQUID" -k parse -f "$T/squid.conf" > "$OUT/parse.txt" 2>&1; then
    pass "squid -k parse exits 0"
else
    fail "squid -k parse failed (see $OUT/parse.txt)"
fi

# 2. per-request verdicts
echo "[simulate] verdicts and deciding rules"
"$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" > "$OUT/simulate.txt" 2> "$OUT/simulate.err"
echo "  exit $?"
# first line of every record: "<line>  <VERDICT>  <rule> ... (log X/Y: <vs>)"
verdicts() {
    awk '$1 ~ /^[0-9]+$/ { vs = "*"; if (match($0, /: [A-Za-z\/]+\)$/)) vs = substr($0, RSTART + 2, RLENGTH - 3); print $1, $2, $3, vs }' "$1"
}
verdicts "$OUT/simulate.txt" > "$OUT/simulate.got"
while read -r line verdict rule vs; do
    case "$line" in ''|\#*) continue ;; esac
    got=$(awk -v l="$line" '$1 == l' "$OUT/simulate.got")
    set -- $got
    if [ "${2:-}" = "$verdict" ] && [ "${3:-}" = "$rule" ] && { [ "$vs" = "*" ] || [ "${4:-}" = "$vs" ]; }; then
        pass "line $line: $verdict $rule $vs"
    else
        fail "line $line: expected '$verdict $rule $vs', got '${2:-} ${3:-} ${4:-}'"
    fi
done < "$T/expected-simulate.txt"
grep -q "matching:   #3 deny > #5 allow" "$OUT/simulate.txt" \
    && pass "matching chain lists the shadowed allow rule" \
    || fail "matching chain for line 4 is missing '#3 deny > #5 allow'"

# 3. config comparison
echo "[compare] --sim-compare"
"$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" --sim-compare "$T/squid-new.conf" \
    > "$OUT/compare.txt" 2> "$OUT/compare.err"
echo "  exit $?"
awk '$1 ~ /^[0-9]+$/ && $3 == "->" { print $1, $2, $4, $5 }' "$OUT/compare.txt" > "$OUT/compare.got"
grep -v '^#' "$T/expected-compare.txt" | awk 'NF' | sed 's/  */ /g' > "$OUT/compare.want"
if diff -u "$OUT/compare.want" "$OUT/compare.got" > "$OUT/compare.diff"; then
    pass "exactly lines $(awk '{printf "%s ", $1}' "$OUT/compare.want")changed"
else
    fail "changed lines differ:"; sed 's/^/        /' "$OUT/compare.diff"
fi

# 4. optimizer findings (config:expected pairs; the second exists on branches that need it)
for pair in squid.conf:expected-optimize.txt optimize-overlap.conf:expected-optimize-overlap.txt \
            optimize-extra.conf:expected-optimize-extra.txt; do
    conf=${pair%%:*} want=${pair##*:}
    [ -f "$T/$want" ] || continue
    echo "[optimize] --optimize ($conf)"
    "$SQUID" -f "$T/$conf" --optimize > "$OUT/optimize-$conf.txt" 2> "$OUT/optimize-$conf.err"
    echo "  exit $?"
    while IFS='|' read -r severity category subject; do
        case "$severity" in ''|\#*) continue ;; esac
        if grep -E "^  $severity +$category +.*$subject" "$OUT/optimize-$conf.txt" > /dev/null; then
            pass "$severity $category $subject"
        else
            fail "missing finding: $severity $category $subject"
        fi
    done < "$T/$want"
done

# 5. HTML report
echo "[report] --report"
"$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" --sim-compare "$T/squid-new.conf" --optimize \
    --report "$OUT/report.html" > "$OUT/report.txt" 2> "$OUT/report.err"
for needle in "<title>Squid ACL Simulation</title>" "Changes: current" "Optimization" "Denied requests by rule" "</html>"; do
    grep -qF "$needle" "$OUT/report.html" 2>/dev/null && pass "report has '$needle'" || fail "report lacks '$needle'"
done

# 6. other log formats: squid-sim converts them as squid-sim.conf says; verdicts must not change
echo "[logformat] scripts/squid-sim with squid-sim.conf"
SIM="$ROOT/scripts/squid-sim"
same_verdicts() {
    verdicts "$OUT/$1.txt" > "$OUT/$1.got"
    if [ -s "$OUT/$1.got" ] && diff -u "$OUT/simulate.got" "$OUT/$1.got" > "$OUT/$1.diff"; then
        pass "$2"
    else
        fail "$2 (see $OUT/$1.err)"; sed 's/^/        /' "$OUT/$1.diff"
    fi
}
"$SIM" --binary "$SQUID" --sim-conf /dev/null -f "$T/squid.conf" --simulate "$T/access.log" \
    > "$OUT/fmt-simul.txt" 2> "$OUT/fmt-simul.err"
same_verdicts fmt-simul "simulformat log is passed to squid unchanged"
# squid_conf and access_log come from the conf; the format is detected
"$SIM" --binary "$SQUID" --sim-conf "$T/sim-squid.conf" > "$OUT/fmt-squid.txt" 2> "$OUT/fmt-squid.err"
same_verdicts fmt-squid "predefined 'squid' format detected (%ts in UTC, local_ip, log_timezone)"
grep -q "logformat squid (detected" "$OUT/fmt-squid.err" \
    && pass "detection is reported" || fail "no 'logformat squid (detected' in $OUT/fmt-squid.err"
gzip -c "$T/access-squid.log" > "$OUT/access-squid.log.gz"
"$SIM" --binary "$SQUID" --sim-conf "$T/sim-squid.conf" --simulate "$OUT/access-squid.log.gz" \
    > "$OUT/fmt-gz.txt" 2> "$OUT/fmt-gz.err"
same_verdicts fmt-gz "gzip-compressed log"
"$SIM" --binary "$SQUID" --sim-conf "$T/sim-custom.conf" > "$OUT/fmt-custom.txt" 2> "$OUT/fmt-custom.err"
same_verdicts fmt-custom "logformat defined in squid-sim.conf (%tg, quoted fields, extra codes)"

echo
echo "outputs: $OUT"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILED TEST(S) FAILED"
fi
[ "$FAILED" -eq 0 ]

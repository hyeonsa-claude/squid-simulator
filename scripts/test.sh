#!/usr/bin/env bash
########
# test.sh -> PASS/FAIL 줄, 마지막에 ALL TESTS PASSED (종료 코드 0) 또는 N TEST(S) FAILED (1)
# tests/의 설정과 로그로 패치한 squid와 scripts/squid-sim을 실행해 tests/expected-*.txt와 비교한다.
# 사용법: scripts/test.sh [패치한 squid 경로]  (기본: build/squid-*/src/squid)
########
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SQUID=${1:-$(ls -d "$ROOT"/build/squid-*/src/squid 2>/dev/null | head -1)}
SIM="$ROOT/scripts/squid-sim"
T="$ROOT/tests"
OUT=$(mktemp -d)
FAILED=0

########
# pass -> PASS 줄
# 통과한 검사 하나를 출력한다.
########
pass() { echo "  PASS  $1"; }

########
# fail -> FAIL 줄 (FAILED 증가)
# 실패한 검사 하나를 출력하고 센다.
########
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

########
# expect_exit -> PASS 또는 FAIL 줄
# 직전 실행의 종료 코드($1)가 0인지 확인한다. 출력이 맞아도 종료 직전에 죽는 경우를 잡는다. $2는 실행 이름.
########
expect_exit() {
    if [ "$1" -eq 0 ]; then
        pass "$2 exits 0"
    else
        fail "$2 exited with $1"
    fi
}

########
# verdicts -> "줄번호 판정 판정규칙 로그비교" 줄들
# 요청별 출력에서 각 요청의 첫 줄 "<줄> <판정> <규칙> ... (log X/Y: <비교>)"만 골라 비교하기 쉬운 형태로 바꾼다.
########
verdicts() {
    awk '$1 ~ /^[0-9]+$/ { vs = "*"; if (match($0, /: [A-Za-z\/]+\)$/)) vs = substr($0, RSTART + 2, RLENGTH - 3); print $1, $2, $3, vs }' "$1"
}

########
# test_parse -> PASS 또는 FAIL 줄
# 패치한 바이너리가 원래 squid처럼 -k parse로 테스트 설정을 받아들이는지 확인한다.
########
test_parse() {
    echo "[parse] squid -k parse"
    if "$SQUID" -k parse -f "$T/squid.conf" > "$OUT/parse.txt" 2>&1; then
        pass "squid -k parse exits 0"
    else
        fail "squid -k parse failed (see $OUT/parse.txt)"
    fi
}

########
# test_simulate -> PASS 또는 FAIL 줄들
# tests/access.log를 재생해 줄마다 판정, 판정 규칙, 로그 비교가 expected-simulate.txt와 같은지,
# 그리고 차단된 요청의 매칭 사슬에 뒤의 allow 규칙이 나오는지 확인한다. 결과는 다른 검사의 기준(simulate.got)이 된다.
########
test_simulate() {
    local rc line verdict rule vs got
    echo "[simulate] verdicts and deciding rules"
    "$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" > "$OUT/simulate.txt" 2> "$OUT/simulate.err"
    rc=$?
    expect_exit "$rc" "--simulate"
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
    if grep -q "matching:   #3 deny > #5 allow" "$OUT/simulate.txt"; then
        pass "matching chain lists the shadowed allow rule"
    else
        fail "matching chain for line 4 is missing '#3 deny > #5 allow'"
    fi
}

########
# test_compare -> PASS 또는 FAIL 줄들
# --sim-compare로 tests/squid-new.conf와 비교해, 결과가 바뀐 줄이 정확히 expected-compare.txt와 같은지 확인한다.
########
test_compare() {
    local rc
    echo "[compare] --sim-compare"
    "$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" --sim-compare "$T/squid-new.conf" \
        > "$OUT/compare.txt" 2> "$OUT/compare.err"
    rc=$?
    expect_exit "$rc" "--sim-compare"
    awk '$1 ~ /^[0-9]+$/ && $3 == "->" { print $1, $2, $4, $5 }' "$OUT/compare.txt" > "$OUT/compare.got"
    grep -v '^#' "$T/expected-compare.txt" | awk 'NF' | sed 's/  */ /g' > "$OUT/compare.want"
    if diff -u "$OUT/compare.want" "$OUT/compare.got" > "$OUT/compare.diff"; then
        pass "exactly lines $(awk '{printf "%s ", $1}' "$OUT/compare.want")changed"
    else
        fail "changed lines differ:"
        sed 's/^/        /' "$OUT/compare.diff"
    fi
}

########
# test_optimize -> PASS 또는 FAIL 줄들
# 설정:기대결과 쌍마다 --optimize를 실행해 기대한 (심각도, 항목, 대상) 결과가 모두 나오는지 확인한다.
# 기대 결과 파일이 없는 쌍(다른 브랜치 전용)은 건너뛴다.
########
test_optimize() {
    local pair conf want rc severity category subject
    for pair in squid.conf:expected-optimize.txt optimize-overlap.conf:expected-optimize-overlap.txt \
                optimize-extra.conf:expected-optimize-extra.txt; do
        conf=${pair%%:*} want=${pair##*:}
        [ -f "$T/$want" ] || continue
        echo "[optimize] --optimize ($conf)"
        "$SQUID" -f "$T/$conf" --optimize > "$OUT/optimize-$conf.txt" 2> "$OUT/optimize-$conf.err"
        rc=$?
        expect_exit "$rc" "--optimize ($conf)"
        while IFS='|' read -r severity category subject; do
            case "$severity" in ''|\#*) continue ;; esac
            if grep -E "^  $severity +$category +.*$subject" "$OUT/optimize-$conf.txt" > /dev/null; then
                pass "$severity $category $subject"
            else
                fail "missing finding: $severity $category $subject"
            fi
        done < "$T/$want"
    done
}

########
# test_report -> PASS 또는 FAIL 줄들
# 재생, 비교, 최적화를 한 번에 실행해 HTML 리포트에 필수 구역이 모두 있는지 확인한다.
########
test_report() {
    local rc needle
    echo "[report] --report"
    "$SQUID" -f "$T/squid.conf" --simulate "$T/access.log" --sim-compare "$T/squid-new.conf" --optimize \
        --report "$OUT/report.html" > "$OUT/report.txt" 2> "$OUT/report.err"
    rc=$?
    expect_exit "$rc" "--report"
    for needle in "<title>Squid ACL Simulation</title>" "Changes: current" "Optimization" "Denied requests by rule" "</html>"; do
        if grep -qF "$needle" "$OUT/report.html" 2>/dev/null; then
            pass "report has '$needle'"
        else
            fail "report lacks '$needle'"
        fi
    done
}

########
# same_verdicts -> PASS 또는 FAIL 줄
# squid-sim 실행($1.txt)이 0으로 끝났고($3), 요청별 결과가 simulformat 원본(simulate.got)과 한 줄도 다르지 않은지 확인한다.
########
same_verdicts() {
    verdicts "$OUT/$1.txt" > "$OUT/$1.got"
    if [ "$3" -eq 0 ] && [ -s "$OUT/$1.got" ] && diff -u "$OUT/simulate.got" "$OUT/$1.got" > "$OUT/$1.diff"; then
        pass "$2"
    else
        fail "$2 (exit $3, see $OUT/$1.err)"
        sed 's/^/        /' "$OUT/$1.diff" 2>/dev/null
    fi
}

########
# test_logformats -> PASS 또는 FAIL 줄들
# 같은 요청을 다른 형식으로 적은 로그를 squid-sim으로 재생해 판정이 바뀌지 않는지 확인한다:
# simulformat 그대로 전달, squid 형식 자동 판별(%ts, local_ip, log_timezone), gzip, 표준 입력,
# squid-sim.conf에 정의한 형식(%tg, 따옴표 안 공백, 쓰지 않는 코드).
########
test_logformats() {
    local rc
    echo "[logformat] scripts/squid-sim with squid-sim.conf"
    "$SIM" --binary "$SQUID" --sim-conf /dev/null -f "$T/squid.conf" --simulate "$T/access.log" \
        > "$OUT/fmt-simul.txt" 2> "$OUT/fmt-simul.err"
    rc=$?
    same_verdicts fmt-simul "simulformat log is passed to squid unchanged" "$rc"

    "$SIM" --binary "$SQUID" --sim-conf "$T/sim-squid.conf" > "$OUT/fmt-squid.txt" 2> "$OUT/fmt-squid.err"
    rc=$?
    same_verdicts fmt-squid "predefined 'squid' format detected (%ts in UTC, local_ip, log_timezone)" "$rc"
    if grep -q "logformat squid (detected" "$OUT/fmt-squid.err"; then
        pass "detection is reported"
    else
        fail "no 'logformat squid (detected' in $OUT/fmt-squid.err"
    fi

    gzip -c "$T/access-squid.log" > "$OUT/access-squid.log.gz"
    "$SIM" --binary "$SQUID" --sim-conf "$T/sim-squid.conf" --simulate "$OUT/access-squid.log.gz" \
        > "$OUT/fmt-gz.txt" 2> "$OUT/fmt-gz.err"
    rc=$?
    same_verdicts fmt-gz "gzip-compressed log" "$rc"

    "$SIM" --binary "$SQUID" --sim-conf "$T/sim-squid.conf" --simulate - < "$T/access-squid.log" \
        > "$OUT/fmt-stdin.txt" 2> "$OUT/fmt-stdin.err"
    rc=$?
    same_verdicts fmt-stdin "log read from standard input" "$rc"

    "$SIM" --binary "$SQUID" --sim-conf "$T/sim-custom.conf" > "$OUT/fmt-custom.txt" 2> "$OUT/fmt-custom.err"
    rc=$?
    same_verdicts fmt-custom "logformat defined in squid-sim.conf (%tg, quoted fields, extra codes)" "$rc"
}

if [ -z "$SQUID" ] || [ ! -x "$SQUID" ]; then
    echo "patched squid binary not found; run scripts/build.sh first or pass its path" >&2
    exit 2
fi
echo "squid: $SQUID ($("$SQUID" -v | head -1))"

test_parse
test_simulate
test_compare
test_optimize
test_report
test_logformats

echo
echo "outputs: $OUT"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILED TEST(S) FAILED"
fi
[ "$FAILED" -eq 0 ]

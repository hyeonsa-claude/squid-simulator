#!/usr/bin/env bash
# Full verification on this branch's target OS, in one run:
#  1. the OS and the distribution's squid version match the branch
#  2. build from the official tarball (+ distribution patches) with -Werror and "make check"
#  3. simulator functional tests (scripts/test.sh)
#  4. the distribution's squid and the patched squid accept the same configs
#  5. the running squid is untouched by all of the above (PID, start time, restarts, cache.log)
#  6. squid-sim --manager can read and record the running squid's cache manager
# Usage: scripts/verify-target.sh [--no-deps] [--no-build]
#   --no-deps   do not install build packages (otherwise needs sudo for apt-get)
#   --no-build  reuse an existing build/ instead of building again (skips make check)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=target.env
. "$ROOT/scripts/target.env"
cd "$ROOT"

DEPS=--deps BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-deps) DEPS= ;;
        --no-build) BUILD=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
STATUS=0
note() { echo "== $*"; }
warn() { echo "!! $*"; STATUS=1; }

note "target of this branch: $TARGET_OS, squid $SQUID_VERSION"
os=$(. /etc/os-release && echo "$PRETTY_NAME")
note "this machine: $os"
case "$os" in
    *"${TARGET_OS%% LTS*}"*) ;;
    *) warn "this machine is not $TARGET_OS; results apply to this machine only" ;;
esac

distro_squid=$(command -v squid || true)
if [ -n "$distro_squid" ]; then
    installed=$("$distro_squid" -v | head -1)
    note "distribution squid: $installed"
    echo "$installed" | grep -q "Version $SQUID_VERSION\$" || warn "installed squid is not $SQUID_VERSION (apt-get upgrade squid?)"
else
    warn "squid is not installed (sudo apt-get install squid); skipping the parse comparison"
fi

# state of the running squid, to prove that the simulator leaves it alone
running_state() {
    local svc log=""
    svc=$(systemctl show squid -p MainPID -p ActiveEnterTimestamp -p NRestarts 2>/dev/null | sort | tr '\n' ' ')
    if sudo -n true 2>/dev/null; then
        log="cache.log=$(sudo -n stat -c %s /var/log/squid/cache.log 2>/dev/null)B"
    elif [ -r /var/log/squid/cache.log ]; then
        log="cache.log=$(stat -c %s /var/log/squid/cache.log)B"
    fi
    echo "$svc$log"
}
squid_running=0
systemctl is-active --quiet squid 2>/dev/null && squid_running=1
before=$(running_state)

if [ "$BUILD" = 1 ]; then
    note "build + make check"
    # shellcheck disable=SC2086
    scripts/build.sh $DEPS --check || { warn "build or make check failed"; exit 1; }
else
    note "build: reusing build/ (--no-build)"
fi
ours="$ROOT/build/squid-$SQUID_VERSION/src/squid"
[ -x "$ours" ] || { warn "no patched squid at $ours"; exit 1; }

note "functional tests"
scripts/test.sh "$ours" || warn "functional tests failed"

if [ -n "$distro_squid" ]; then
    note "parse comparison: distribution squid vs patched squid"
    for conf in tests/squid.conf tests/squid-new.conf /etc/squid/squid.conf; do
        [ -r "$conf" ] || { echo "   skip $conf (not readable)"; continue; }
        "$distro_squid" -k parse -f "$conf" > /dev/null 2>&1; a=$?
        "$ours" -k parse -f "$conf" > /dev/null 2>&1; b=$?
        if [ "$a" = "$b" ]; then
            echo "   same result ($a): $conf"
        else
            warn "different -k parse results for $conf: distribution=$a patched=$b"
        fi
    done
    if [ -r /etc/squid/squid.conf ]; then
        note "optimizer on this machine's /etc/squid/squid.conf"
        "$ours" -f /etc/squid/squid.conf --simulate tests/access.log --optimize > /dev/null 2>&1
        "$ours" -f /etc/squid/squid.conf --optimize 2>/dev/null | head -40
    fi
fi

if [ "$squid_running" = 1 ]; then
    note "running squid untouched by the simulator"
    after=$(running_state)
    echo "   before: $before"
    echo "   after:  $after"
    [ "$before" = "$after" ] || warn "the running squid changed while the simulator ran"

    note "cache manager (scripts/squid-sim --manager)"
    out=$(scripts/squid-sim -m 2>&1); rc=$?
    if [ "$rc" = 0 ] && echo "$out" | grep -q "^# squid "; then
        echo "   one-shot: $(echo "$out" | head -1)"
    else
        warn "squid-sim -m failed (exit $rc): $(echo "$out" | tail -1)"
    fi
    dir=$(mktemp -d)
    if scripts/squid-sim -m --report 40s --interval 20s --out "$dir" > "$dir/run.log" 2>&1 &&
        [ -s "$dir/report.html" ] && [ -s "$dir/summary.txt" ] && [ -s "$dir/snapshots.jsonl" ]; then
        echo "   recording: $(grep -c '' "$dir/snapshots.jsonl") polls, report in $dir"
    else
        warn "squid-sim -m --report failed: $(tail -1 "$dir/run.log")"
    fi
else
    note "squid is not running: skipping the running-squid and cache manager checks"
fi

echo
if [ "$STATUS" = 0 ]; then
    echo "VERIFICATION PASSED on $os"
else
    echo "VERIFICATION FINISHED WITH WARNINGS on $os (see !! lines)"
fi
exit "$STATUS"

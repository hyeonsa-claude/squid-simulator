#!/usr/bin/env bash
# Full verification on this branch's target OS, in one run:
#  1. the OS and the distribution's squid version match the branch
#  2. build from the official tarball (+ distribution patches) with -Werror and "make check"
#  3. simulator functional tests (scripts/test.sh)
#  4. the distribution's squid and the patched squid accept the same configs
# Usage: scripts/verify-target.sh [--no-deps]     (needs sudo for apt-get unless --no-deps)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=target.env
. "$ROOT/scripts/target.env"
cd "$ROOT"

DEPS=--deps
[ "${1:-}" = "--no-deps" ] && DEPS=
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

note "build + make check"
# shellcheck disable=SC2086
scripts/build.sh $DEPS --check || { warn "build or make check failed"; exit 1; }
ours="$ROOT/build/squid-$SQUID_VERSION/src/squid"

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
        "$ours" -f /etc/squid/squid.conf --optimize 2>/dev/null | head -40
    fi
fi

echo
if [ "$STATUS" = 0 ]; then
    echo "VERIFICATION PASSED on $os"
else
    echo "VERIFICATION FINISHED WITH WARNINGS on $os (see !! lines)"
fi
exit "$STATUS"

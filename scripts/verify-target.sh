#!/usr/bin/env bash
########
# verify-target.sh -> "== / !!" 진행 줄, 마지막에 VERIFICATION PASSED (종료 코드 0) 또는 WITH WARNINGS (1)
# 이 브랜치의 대상 OS에서 한 번에 전체를 검증한다.
#   1. OS와 배포판 squid 버전이 브랜치와 맞는지
#   2. 공식 tarball(+배포판 패치)로 -Werror 빌드와 make check
#   3. 시뮬레이터 기능 테스트(scripts/test.sh)
#   4. 배포판 squid와 패치한 squid가 같은 설정을 같게 받아들이는지, 이 서버 설정으로 최적화가 정상 종료하는지
#   5. 위 모든 작업 동안 실행 중인 squid가 그대로인지(PID, 시작 시각, 재시작 횟수, cache.log 크기)
#   6. squid-sim --manager가 실행 중인 squid의 캐시 매니저를 읽고 기록하는지
# 사용법: scripts/verify-target.sh [--no-deps] [--no-build]
#   --no-deps   빌드 패키지를 설치하지 않음 (기본은 sudo apt-get 사용)
#   --no-build  기존 build/를 다시 쓰고 make check를 건너뜀
########
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/target.env"
cd "$ROOT"

DEPS=--deps BUILD=1 STATUS=0
OURS="$ROOT/build/squid-$SQUID_VERSION/src/squid"
DISTRO_SQUID=$(command -v squid || true)
OS_NAME=$(. /etc/os-release && echo "$PRETTY_NAME")

########
# note -> "== " 줄
# 진행 상황 한 줄을 출력한다.
########
note() { echo "== $*"; }

########
# warn -> "!! " 줄 (STATUS=1)
# 문제 한 줄을 출력하고 최종 결과를 경고로 바꾼다.
########
warn() { echo "!! $*"; STATUS=1; }

########
# parse_args -> DEPS, BUILD 설정
# 명령행 옵션을 읽는다. 모르는 옵션이면 종료 코드 2로 끝낸다.
########
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --no-deps) DEPS= ;;
            --no-build) BUILD=0 ;;
            *) echo "unknown option: $arg" >&2; exit 2 ;;
        esac
    done
}

########
# check_target -> note/warn 줄
# 이 서버의 OS 이름과 설치된 squid 버전이 target.env의 대상과 같은지 확인한다.
########
check_target() {
    local installed
    note "target of this branch: $TARGET_OS, squid $SQUID_VERSION"
    note "this machine: $OS_NAME"
    case "$OS_NAME" in
        *"${TARGET_OS%% LTS*}"*) ;;
        *) warn "this machine is not $TARGET_OS; results apply to this machine only" ;;
    esac
    if [ -n "$DISTRO_SQUID" ]; then
        installed=$("$DISTRO_SQUID" -v | head -1)
        note "distribution squid: $installed"
        echo "$installed" | grep -q "Version $SQUID_VERSION\$" || warn "installed squid is not $SQUID_VERSION (apt-get upgrade squid?)"
    else
        warn "squid is not installed (sudo apt-get install squid); skipping the parse comparison"
    fi
}

########
# running_state -> "MainPID=... ActiveEnterTimestamp=... NRestarts=... cache.log=NB"
# 실행 중인 squid 서비스의 상태와 cache.log 크기. 전후 값이 같으면 시뮬레이터가 운영 squid를 건드리지 않은 것이다.
########
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

########
# build_and_check -> 빌드된 $OURS (실패하면 종료 코드 1)
# build.sh --check로 빌드와 make check를 하거나, --no-build면 기존 바이너리를 쓴다.
########
build_and_check() {
    if [ "$BUILD" = 1 ]; then
        note "build + make check"
        scripts/build.sh $DEPS --check || { warn "build or make check failed"; exit 1; }
    else
        note "build: reusing build/ (--no-build)"
    fi
    [ -x "$OURS" ] || { warn "no patched squid at $OURS"; exit 1; }
}

########
# compare_with_distribution -> note/warn 줄
# 테스트 설정과 이 서버의 /etc/squid/squid.conf를 배포판 squid와 패치한 squid로 -k parse해 종료 코드가 같은지 보고,
# 이 서버 설정으로 --simulate --optimize와 --optimize가 0으로 끝나는지 확인한다(출력 앞부분도 보여 준다).
########
compare_with_distribution() {
    local conf a b rc
    note "parse comparison: distribution squid vs patched squid"
    for conf in tests/squid.conf tests/squid-new.conf /etc/squid/squid.conf; do
        [ -r "$conf" ] || { echo "   skip $conf (not readable)"; continue; }
        "$DISTRO_SQUID" -k parse -f "$conf" > /dev/null 2>&1; a=$?
        "$OURS" -k parse -f "$conf" > /dev/null 2>&1; b=$?
        if [ "$a" = "$b" ]; then
            echo "   same result ($a): $conf"
        else
            warn "different -k parse results for $conf: distribution=$a patched=$b"
        fi
    done
    [ -r /etc/squid/squid.conf ] || return 0
    note "optimizer on this machine's /etc/squid/squid.conf"
    "$OURS" -f /etc/squid/squid.conf --simulate tests/access.log --optimize > /dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] || warn "--simulate --optimize on /etc/squid/squid.conf exited with $rc"
    "$OURS" -f /etc/squid/squid.conf --optimize > "$WORK/optimize.txt" 2>/dev/null
    rc=$?
    head -40 "$WORK/optimize.txt"
    [ "$rc" = 0 ] || warn "--optimize on /etc/squid/squid.conf exited with $rc"
}

########
# check_untouched -> note/warn 줄
# 시작 전에 저장한 실행 중인 squid의 상태와 지금 상태가 같은지 비교한다.
########
check_untouched() {
    local after
    note "running squid untouched by the simulator"
    after=$(running_state)
    echo "   before: $BEFORE"
    echo "   after:  $after"
    [ "$BEFORE" = "$after" ] || warn "the running squid changed while the simulator ran"
}

########
# check_manager -> note/warn 줄
# squid-sim -m 한 번 조회가 0으로 끝나고 info(버전)와 counters가 실제로 해석됐는지,
# --report 40초 기록이 report.html, summary.txt, 스냅숏 2개 이상을 남기는지 확인한다.
########
check_manager() {
    local out rc dir polls
    note "cache manager (scripts/squid-sim --manager)"
    out=$(scripts/squid-sim -m 2>&1)
    rc=$?
    if [ "$rc" = 0 ] && echo "$out" | grep -q "^# squid [0-9]" && echo "$out" | grep -q "client_http.requests"; then
        echo "   one-shot: $(echo "$out" | head -1)"
    else
        warn "squid-sim -m failed or parsed nothing (exit $rc): $(echo "$out" | tail -1)"
    fi
    dir="$WORK/manager"
    scripts/squid-sim -m --report 40s --interval 20s --out "$dir" > "$WORK/manager.log" 2>&1
    rc=$?
    polls=$(cat "$dir/snapshots.jsonl" 2>/dev/null | grep -c '')
    if [ "$rc" = 0 ] && [ -s "$dir/report.html" ] && [ -s "$dir/summary.txt" ] && [ "$polls" -ge 2 ]; then
        echo "   recording: $polls polls, report in $dir"
    else
        warn "squid-sim -m --report failed (exit $rc, $polls polls): $(tail -1 "$WORK/manager.log")"
    fi
}

parse_args "$@"
WORK=$(mktemp -d)
check_target
SQUID_RUNNING=0
systemctl is-active --quiet squid 2>/dev/null && SQUID_RUNNING=1
BEFORE=$(running_state)
build_and_check
note "functional tests"
scripts/test.sh "$OURS" || warn "functional tests failed"
[ -n "$DISTRO_SQUID" ] && compare_with_distribution
if [ "$SQUID_RUNNING" = 1 ]; then
    check_untouched
    check_manager
else
    note "squid is not running: skipping the running-squid and cache manager checks"
fi

echo
if [ "$STATUS" = 0 ]; then
    echo "VERIFICATION PASSED on $OS_NAME"
else
    echo "VERIFICATION FINISHED WITH WARNINGS on $OS_NAME (see !! lines)"
fi
exit "$STATUS"

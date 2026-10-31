#!/usr/bin/env bash
########
# build.sh -> build/squid-<버전>/src/squid (패치한 squid 바이너리)
# 이 브랜치의 squid 공식 소스를 받아 SHA-256을 확인하고, 배포판 패치(있으면)와 시뮬레이터 패치를 적용해
# build/ 아래에서 빌드한다. 아무것도 설치하지 않는다.
# 사용법: scripts/build.sh [--deps] [--check] [-jN]
#   --deps   먼저 sudo apt-get으로 빌드 패키지를 설치
#   --check  make check(Squid 자체 단위 테스트)까지 실행
########
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/target.env"

DEPS=0 CHECK=0 JOBS=$(nproc)

########
# parse_args -> DEPS, CHECK, JOBS 설정
# 명령행 옵션을 읽는다. 모르는 옵션이면 종료 코드 2로 끝낸다.
########
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --deps) DEPS=1 ;;
            --check) CHECK=1 ;;
            -j*) JOBS=${arg#-j} ;;
            *) echo "unknown option: $arg" >&2; exit 2 ;;
        esac
    done
}

########
# install_deps -> 없음 (패키지 설치)
# --deps일 때 target.env의 BUILD_DEPS를 apt-get으로 설치한다. BUILD_DEPS는 패키지 목록이라 일부러 단어로 나눈다.
########
install_deps() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $BUILD_DEPS
}

########
# fetch_source -> build/squid-<버전>/ (풀어 둔 공식 소스)
# 공식 tarball을 받아(실패하면 미러) SHA-256을 확인하고, 이전 소스 디렉터리를 지운 뒤 새로 푼다.
########
fetch_source() {
    mkdir -p "$ROOT/build"
    cd "$ROOT/build"
    if [ ! -f "$SQUID_TARBALL" ]; then
        curl -fL -o "$SQUID_TARBALL" "$SQUID_URL" || curl -fL -o "$SQUID_TARBALL" "$SQUID_URL_MIRROR"
    fi
    echo "$SQUID_SHA256  $SQUID_TARBALL" | sha256sum -c -
    rm -rf "squid-$SQUID_VERSION"
    tar xf "$SQUID_TARBALL"
    cd "squid-$SQUID_VERSION"
}

########
# apply_patches -> 패치가 적용된 소스
# target.env에 배포판 debian tarball이 있으면 받아 확인하고 DISTRO_PATCHES(squid 자체를 바꾸는 것만)를 먼저 적용한다.
# 그다음 이 저장소의 시뮬레이터 패치를 적용한다. 하나라도 어긋나면 set -e로 멈춘다.
########
apply_patches() {
    local debian_tarball p
    if [ -n "${DISTRO_DEBIAN_URL:-}" ]; then
        debian_tarball=$(basename "$DISTRO_DEBIAN_URL")
        [ -f "../$debian_tarball" ] || curl -fL -o "../$debian_tarball" "$DISTRO_DEBIAN_URL"
        (cd .. && echo "$DISTRO_DEBIAN_SHA256  $debian_tarball" | sha256sum -c -)
        rm -rf ../debian && tar xf "../$debian_tarball" -C ..
        for p in $DISTRO_PATCHES; do
            echo "distribution patch: $p"
            patch -p1 < "../debian/patches/$p"
        done
    fi
    patch -p1 < "$ROOT/$PATCH_FILE"
}

########
# compile -> build/squid-<버전>/src/squid
# 배포판과 같은 configure 옵션(target.env)으로 설정하고 빌드한다. 실패하면 로그의 오류 부분만 보여 주고 끝낸다.
########
compile() {
    ./configure $CONFIGURE_OPTS > ../configure.log 2>&1 || { tail -30 ../configure.log; exit 1; }
    make -j"$JOBS" > ../make.log 2>&1 || { grep -n -B2 -A6 -E "error:|Error " ../make.log | head -80; exit 1; }
    echo "built: $ROOT/build/squid-$SQUID_VERSION/src/squid"
    "$ROOT/build/squid-$SQUID_VERSION/src/squid" -v | head -1
}

########
# run_checks -> 없음 (실패하면 종료 코드 1)
# make check로 Squid 자체 단위 테스트를 돌리고 PASS/FAIL 집계를 보여 준다.
########
run_checks() {
    make -j"$JOBS" check > ../check.log 2>&1 || { grep -n -E "FAIL|error:" ../check.log | head -40; exit 1; }
    grep -E "^# (TOTAL|PASS|FAIL|ERROR)" ../check.log | sort | uniq -c || true
    echo "make check passed"
}

parse_args "$@"
echo "target: $TARGET_OS, squid $SQUID_VERSION"
[ "$DEPS" = 1 ] && install_deps
fetch_source
apply_patches
compile
[ "$CHECK" = 1 ] && run_checks
exit 0

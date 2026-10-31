#!/usr/bin/env bash
# Downloads the squid release of this branch, verifies it, applies the simulator
# patch and builds it under build/. Nothing is installed.
# Usage: scripts/build.sh [--deps] [--check] [-jN]
#   --deps   install build packages with sudo apt-get first
#   --check  also run "make check" (Squid's own unit tests)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=target.env
. "$ROOT/scripts/target.env"

DEPS=0 CHECK=0 JOBS=$(nproc)
for arg in "$@"; do
    case "$arg" in
        --deps) DEPS=1 ;;
        --check) CHECK=1 ;;
        -j*) JOBS=${arg#-j} ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "target: $TARGET_OS, squid $SQUID_VERSION"

if [ "$DEPS" = 1 ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    # shellcheck disable=SC2086
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $BUILD_DEPS
fi

mkdir -p "$ROOT/build"
cd "$ROOT/build"
if [ ! -f "$SQUID_TARBALL" ]; then
    curl -fL -o "$SQUID_TARBALL" "$SQUID_URL" || curl -fL -o "$SQUID_TARBALL" "$SQUID_URL_MIRROR"
fi
echo "$SQUID_SHA256  $SQUID_TARBALL" | sha256sum -c -

SRC="squid-$SQUID_VERSION"
rm -rf "$SRC"
tar xf "$SQUID_TARBALL"
cd "$SRC"

# the distribution's own source patches (only those that change squid itself)
if [ -n "${DISTRO_DEBIAN_URL:-}" ]; then
    DEBIAN_TARBALL=$(basename "$DISTRO_DEBIAN_URL")
    [ -f "../$DEBIAN_TARBALL" ] || curl -fL -o "../$DEBIAN_TARBALL" "$DISTRO_DEBIAN_URL"
    (cd .. && echo "$DISTRO_DEBIAN_SHA256  $DEBIAN_TARBALL" | sha256sum -c -)
    rm -rf ../debian && tar xf "../$DEBIAN_TARBALL" -C ..
    for p in $DISTRO_PATCHES; do
        echo "distribution patch: $p"
        patch -p1 < "../debian/patches/$p"
    done
fi

patch -p1 < "$ROOT/$PATCH_FILE"

# shellcheck disable=SC2086
./configure $CONFIGURE_OPTS > ../configure.log 2>&1 || { tail -30 ../configure.log; exit 1; }
make -j"$JOBS" > ../make.log 2>&1 || { grep -n -B2 -A6 -E "error:|Error " ../make.log | head -80; exit 1; }
echo "built: $ROOT/build/$SRC/src/squid"
"$ROOT/build/$SRC/src/squid" -v | head -1

if [ "$CHECK" = 1 ]; then
    make -j"$JOBS" check > ../check.log 2>&1 || { grep -n -E "FAIL|error:" ../check.log | head -40; exit 1; }
    grep -E "^# (TOTAL|PASS|FAIL|ERROR)" ../check.log | sort | uniq -c || true
    echo "make check passed"
fi

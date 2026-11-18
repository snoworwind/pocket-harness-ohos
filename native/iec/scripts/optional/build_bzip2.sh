#!/bin/bash
# build_bzip2.sh — static libbz2 for the other command builds (tar -j, python _bz2).
#
# bzip2 1.0.8 has no configure; its Makefile takes CC/CFLAGS/AR/RANLIB directly,
# and the only products we need are libbz2.a and bzlib.h. The bzip2 CLI itself is
# not shipped: every consumer links the library, so nothing has to spawn an
# external `bzip2` program.
#
# Output:
#   $IEC_DEPS_LIB/libbz2.a
#   $IEC_DEPS_INC/bzlib.h
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

BZ2_VER="${BZ2_VER:-1.0.8}"
URL="${BZ2_URL:-https://sourceware.org/pub/bzip2/bzip2-$BZ2_VER.tar.gz}"
# 上游只发布 sha512.sum，没有 SHA-256；未固定时普通构建告警，CI/AUDIT_STRICT=1 失败。
SHA256="$(iec_sha_or IEC_BZIP2_SHA256 ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269)"
SOURCE_CACHE="${IEC_SOURCE_CACHE:-$IEC_ROOT/thirdparty}"
[ -d "$SOURCE_CACHE" ] || SOURCE_CACHE="$IEC_THIRDPARTY"
TAR="$SOURCE_CACHE/bzip2-$BZ2_VER.tar.gz"
SRC="${BZ2_SRC:-$SOURCE_CACHE/bzip2-$BZ2_VER}"
BLD="${BZ2_BUILD:-$IEC_ROOT/build/bzip2}"
AR="${AR:-$CLANG_DIR/llvm-ar}"
RANLIB="${RANLIB:-$CLANG_DIR/llvm-ranlib}"

if [ -f "$IEC_DEPS_LIB/libbz2.a" ] && [ -f "$IEC_DEPS_INC/bzlib.h" ]; then
	iec_log "bzip2 already built: $IEC_DEPS_LIB/libbz2.a"
	exit 0
fi

if [ ! -f "$SRC/Makefile" ]; then
	mkdir -p "$SOURCE_CACHE"
	iec_fetch_verified "$URL" "$TAR" "$SHA256" "bzip2 $BZ2_VER"
	iec_log "extract bzip2 $BZ2_VER -> $SOURCE_CACHE"
	mkdir -p "$SRC"
	tar -xzf "$TAR" -C "$SRC" --strip-components=1
fi
[ -f "$SRC/Makefile" ] || iec_err "unexpected bzip2 source layout: $SRC"

rm -rf "$BLD"
mkdir -p "$BLD" "$IEC_DEPS_LIB" "$IEC_DEPS_INC"

# bzip2's Makefile assembles objects in the source tree, so build in a copy to
# keep the cached source pristine.
cp -a "$SRC/." "$BLD/"
iec_log "build libbz2.a"
make -C "$BLD" -j"$JOBS" libbz2.a \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
	CFLAGS="-O2 -fPIC" AR="$AR" RANLIB="$RANLIB" \
	> "$BLD/make.log" 2>&1 \
	|| { tail -30 "$BLD/make.log" >&2; iec_err "bzip2 make failed"; }
[ -f "$BLD/libbz2.a" ] || iec_err "libbz2.a was not built"

cp -f "$BLD/libbz2.a" "$IEC_DEPS_LIB/"
cp -f "$SRC/bzlib.h" "$IEC_DEPS_INC/"
iec_log "bzip2 ready: $IEC_DEPS_LIB/libbz2.a"

#!/bin/bash
# build_xz.sh — xz CLI and liblzma as an IEC command object.
#
# liblzma is installed into the IEC dependency prefix too, so CPython's _lzma
# can be enabled by a later configure pass.
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libxzcmd.so
#   build/deps/usr/lib/<target>/liblzma.a
#   build/deps/usr/include/lzma.h
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

XZ_VER="${XZ_VER:-5.8.1}"
TAR="$IEC_THIRDPARTY/xz-$XZ_VER.tar.gz"
SRC="$IEC_THIRDPARTY/xz-$XZ_VER"
BLD="$IEC_ROOT/build/xz-build"
WORK="$IEC_ROOT/build/xz"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR" "$IEC_THIRDPARTY"
if [ ! -s "$TAR" ]; then
	curl -L --retry 3 -m 600 -o "$TAR.part" "https://tukaani.org/xz/xz-$XZ_VER.tar.gz" \
		|| iec_err "xz download failed"
	mv "$TAR.part" "$TAR"
fi
if [ ! -f "$SRC/configure" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

if [ ! -f "$BLD/Makefile" ]; then
	rm -rf "$BLD"
	mkdir -p "$BLD"
	( cd "$BLD" && SKIP_WERROR_CHECK=yes "$SRC/configure" \
		--host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
		--disable-shared --enable-static --disable-doc --disable-nls \
		--disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts \
		CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" CFLAGS="-O2 -fPIC" \
		> "$WORK/configure.log" 2>&1 ) \
		|| { tail -30 "$WORK/configure.log" >&2; iec_err "xz configure failed"; }
fi

make -C "$BLD/src/liblzma" -j"$JOBS" > "$WORK/liblzma-make.log" 2>&1 \
	|| { tail -30 "$WORK/liblzma-make.log" >&2; iec_err "liblzma build failed"; }
make -C "$BLD/src/xz" -j"$JOBS" xz > "$WORK/xz-make.log" 2>&1 \
	|| { tail -30 "$WORK/xz-make.log" >&2; iec_err "xz CLI build failed"; }

# Install liblzma + headers for CPython's _lzma module.
mkdir -p "$IEC_DEPS_LIB" "$IEC_DEPS_INC/lzma"
cp -f "$BLD/src/liblzma/.libs/liblzma.a" "$IEC_DEPS_LIB/"
cp -f "$SRC/src/liblzma/api/lzma.h" "$IEC_DEPS_INC/"
cp -f "$SRC"/src/liblzma/api/lzma/*.h "$IEC_DEPS_INC/lzma/"

# Recompile main.c with default visibility: xz's normal objects are compiled
# with -fvisibility=hidden, which would hide the IEC entry symbol.
$CC_TARGET -O2 -fPIC -DHAVE_CONFIG_H -I"$BLD" -I"$SRC/src/xz" \
	-I"$SRC/src/common" -I"$SRC/src/liblzma/api" \
	-Dmain=iec_xz_main -fvisibility=default \
	-c "$SRC/src/xz/main.c" -o "$WORK/xz_main.o"

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"

declare -a OBJS=()
while IFS= read -r obj; do
	[ "$(basename "$obj")" = "xz-main.o" ] && continue
	OBJS+=("$obj")
done < <(find "$BLD/src/xz" -maxdepth 1 -name 'xz-*.o' | sort)

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libxzcmd.so" "$WORK/xz_main.o" "${OBJS[@]}" \
	"$BLD/src/liblzma/.libs/liblzma.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libxzcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libxzcmd.so" \
	| grep ' iec_xz_main$' >/dev/null || iec_err "xz: entry iec_xz_main is not exported"
iec_log "done: $OUT_DIR/libxzcmd.so"

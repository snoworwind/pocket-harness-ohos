#!/bin/bash
# build_zstd.sh — zstd CLI and libzstd as an IEC command object.
#
# zstd's dictionary trainer uses qsort_r(), which OHOS libc does not declare.
# scripts/optional/compat_qsort_r.c provides the glibc-order adapter; it is
# linked into both the CLI and (implicitly) every consumer of libzstd.a.
#
# Output: platform/ohos/har/libs/arm64-v8a/libzstdcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

ZSTD_VER="${ZSTD_VER:-1.5.7}"
TAR="$IEC_THIRDPARTY/zstd-$ZSTD_VER.tar.gz"
SRC="$IEC_THIRDPARTY/zstd-$ZSTD_VER"
WORK="$IEC_ROOT/build/zstd"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR" "$IEC_THIRDPARTY"
if [ ! -s "$TAR" ]; then
	curl -L --retry 3 -m 600 -o "$TAR.part" \
		"https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz" \
		|| iec_err "zstd download failed"
	mv "$TAR.part" "$TAR"
fi
if [ ! -f "$SRC/lib/Makefile" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

$CC_TARGET -O2 -fPIC -c "$IEC_ROOT/scripts/optional/compat_qsort_r.c" \
	-o "$WORK/compat_qsort_r.o"

make -C "$SRC/lib" -j"$JOBS" libzstd.a \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" CFLAGS="-O2 -fPIC" \
	> "$WORK/libzstd-make.log" 2>&1 \
	|| { tail -30 "$WORK/libzstd-make.log" >&2; iec_err "libzstd build failed"; }
[ -f "$SRC/lib/libzstd.a" ] || iec_err "libzstd.a was not built"

# libarchive (tar) links the same static library, so install it next to zlib.
mkdir -p "$IEC_DEPS_LIB" "$IEC_DEPS_INC"
cp -f "$SRC/lib/libzstd.a" "$IEC_DEPS_LIB/"
cp -f "$SRC/lib/zstd.h" "$SRC/lib/zstd_errors.h" "$SRC/lib/zdict.h" "$IEC_DEPS_INC/"

make -C "$SRC/programs" -j"$JOBS" zstd \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" CFLAGS="-O2 -fPIC" \
	LDFLAGS="$WORK/compat_qsort_r.o -fuse-ld=lld" \
	> "$WORK/zstd-make.log" 2>&1 \
	|| { tail -30 "$WORK/zstd-make.log" >&2; iec_err "zstd CLI build failed"; }

OBJDIR="$(dirname "$(find "$SRC/programs/obj" -name zstdcli.o | head -1)")"
[ -n "$OBJDIR" ] && [ -f "$OBJDIR/zstdcli.o" ] || iec_err "zstdcli.o not found"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_zstd_main \
	"$OBJDIR/zstdcli.o" "$WORK/zstd_main.o"

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"

declare -a OBJS=()
while IFS= read -r obj; do
	[ "$obj" = "$OBJDIR/zstdcli.o" ] && continue
	OBJS+=("$obj")
done < <(find "$OBJDIR" -maxdepth 1 -name '*.o' | sort)

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libzstdcmd.so" "$WORK/zstd_main.o" "${OBJS[@]}" \
	"$SRC/lib/libzstd.a" "$IEC_DEPS_LIB/libz.a" "$WORK/compat_qsort_r.o" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libzstdcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libzstdcmd.so" \
	| grep ' iec_zstd_main$' >/dev/null || iec_err "zstd: entry iec_zstd_main is not exported"
iec_log "done: $OUT_DIR/libzstdcmd.so"

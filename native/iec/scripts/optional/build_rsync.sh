#!/bin/bash
# build_rsync.sh — rsync as an IEC command object.
#
# rsync's bundled popt is used so the device does not need an external popt.
# TLS/zstd/lz4 support is left out to keep the object small and dependency-free;
# rsync:// and ssh transports still work, and ssh/scp come from dropbear.
#
# Output: platform/ohos/har/libs/arm64-v8a/librsynccmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

RSYNC_VER="${RSYNC_VER:-3.4.1}"
TAR="$IEC_THIRDPARTY/rsync-$RSYNC_VER.tar.gz"
# 上游目录只提供 .asc 签名，没有 SHA-256 文件；未固定时 CI 失败，普通构建告警。
SHA256="$(iec_sha_or IEC_RSYNC_SHA256 2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52)"
SRC="$IEC_THIRDPARTY/rsync-$RSYNC_VER"
BLD="$IEC_ROOT/build/rsync"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$BLD" "$OUT_DIR" "$IEC_THIRDPARTY"
iec_fetch_verified "https://download.samba.org/pub/rsync/src/rsync-$RSYNC_VER.tar.gz" \
	"$TAR" "$SHA256" "rsync $RSYNC_VER"
if [ ! -f "$SRC/configure" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

if [ ! -f "$BLD/Makefile" ]; then
	( cd "$BLD" && "$SRC/configure" \
		--host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
		--prefix="$IEC_ROOT/build/rsync-prefix" --with-included-popt \
		--disable-openssl --disable-xxhash --disable-zstd --disable-lz4 --disable-md2man \
		CC="$CC_TARGET" CFLAGS="-O2 -fPIC" LDFLAGS="-fuse-ld=lld" \
		> "$IEC_ROOT/build/rsync-configure.log" 2>&1 ) \
		|| { tail -30 "$IEC_ROOT/build/rsync-configure.log" >&2; iec_err "rsync configure failed"; }
fi

make -C "$BLD" -j"$JOBS" > "$IEC_ROOT/build/rsync-make.log" 2>&1 \
	|| { tail -30 "$IEC_ROOT/build/rsync-make.log" >&2; iec_err "rsync build failed"; }

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_rsync_main \
	"$BLD/main.o" "$BLD/rsync_main.o"

declare -a OBJS=()
while IFS= read -r obj; do
	[ "$(basename "$obj")" = "main.o" ] && continue
	[ "$(basename "$obj")" = "rsync_main.o" ] && continue
	OBJS+=("$obj")
done < <(find "$BLD" -maxdepth 1 -name '*.o' | sort)
while IFS= read -r obj; do
	OBJS+=("$obj")
done < <(find "$BLD/lib" "$BLD/zlib" "$BLD/popt" -maxdepth 1 -name '*.o' | sort)

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/librsynccmd.so" "$BLD/rsync_main.o" "${OBJS[@]}" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,librsynccmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/librsynccmd.so" \
	| grep ' iec_rsync_main$' >/dev/null || iec_err "rsync: entry iec_rsync_main is not exported"
iec_log "done: $OUT_DIR/librsynccmd.so"

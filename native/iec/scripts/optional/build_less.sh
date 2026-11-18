#!/bin/bash
# build_less.sh — less(1) as an IEC command object.
#
# less needs a curses/termcap implementation.  The static ncursesw built by
# build_python.sh is reused; run that script first on a clean tree.
#
# Output: platform/ohos/har/libs/arm64-v8a/liblesscmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

LESS_VER="${LESS_VER:-668}"
TAR="$IEC_THIRDPARTY/less-$LESS_VER.tar.gz"
# 上游下载页未提供机器可读的 SHA-256 文件；未固定时 CI 失败，普通构建告警。
SHA256="$(iec_sha_or IEC_LESS_SHA256 2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8)"
SRC="$IEC_THIRDPARTY/less-$LESS_VER"
BLD="$IEC_ROOT/build/less"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
NC="$IEC_ROOT/build/python/deps"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

[ -f "$NC/lib/libncursesw.a" ] || iec_err "missing $NC/lib/libncursesw.a (run scripts/optional/build_python.sh first)"
mkdir -p "$BLD" "$OUT_DIR" "$IEC_THIRDPARTY"
iec_fetch_verified "https://www.greenwoodsoftware.com/less/less-$LESS_VER.tar.gz" \
	"$TAR" "$SHA256" "less $LESS_VER"
if [ ! -f "$SRC/configure" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

if [ ! -f "$BLD/Makefile" ]; then
	( cd "$BLD" && "$SRC/configure" \
		--host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
		--prefix="$IEC_ROOT/build/less-prefix" --with-regex=posix \
		CC="$CC_TARGET" CFLAGS="-O2 -fPIC -I$NC/include -I$NC/include/ncursesw" \
		LDFLAGS="-L$NC/lib" > "$IEC_ROOT/build/less-configure.log" 2>&1 ) \
		|| { tail -30 "$IEC_ROOT/build/less-configure.log" >&2; iec_err "less configure failed"; }
fi

make -C "$BLD" -j"$JOBS" less > "$IEC_ROOT/build/less-make.log" 2>&1 \
	|| { tail -30 "$IEC_ROOT/build/less-make.log" >&2; iec_err "less build failed"; }

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_less_main \
	"$BLD/main.o" "$BLD/less_main.o"

declare -a OBJS=()
while IFS= read -r obj; do
	case "$(basename "$obj")" in
		main.o|less_main.o) continue ;;
	esac
	OBJS+=("$obj")
done < <(find "$BLD" -maxdepth 1 -name '*.o' | sort)

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/liblesscmd.so" "$BLD/less_main.o" "${OBJS[@]}" \
	"$NC/lib/libncursesw.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,liblesscmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/liblesscmd.so" \
	| grep ' iec_less_main$' >/dev/null || iec_err "less: entry iec_less_main is not exported"
iec_log "done: $OUT_DIR/liblesscmd.so"

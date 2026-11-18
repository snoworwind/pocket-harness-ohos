#!/bin/bash
# build_vim.sh — a small Vim (vi-compatible) as an IEC command object.
#
# Uses the ncursesw static library from build_python.sh.  The runtime files are
# packed separately as vim-runtime.tar.gz so the application can set VIMRUNTIME
# after unpacking; without them Vim still edits, but syntax/help/defaults are
# unavailable.
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libvimcmd.so
#   platform/ohos/har/src/main/resources/rawfile/tools/vim-runtime.tar.gz
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VIM_VER="${VIM_VER:-9.1.1000}"
# tag v9.1.1000 的 commit（api.github.com/repos/vim/vim/git/tags/v9.1.1000）。
# 归档按 commit 取，不再跟随可移动的 tag；SHA-256 仍未固定（CI 会失败）。
VIM_COMMIT="$(iec_sha_or IEC_VIM_COMMIT ebea31e454b9a1731cde845226f2c28ca5c097b1)"
TAR="$IEC_THIRDPARTY/vim-$VIM_VER.tar.gz"
# commit 已固定；commit 归档没有官方 checksum，这里固定该归档的 SHA-256。
SHA256="$(iec_sha_or IEC_VIM_SHA256 9eac83abda00a15712e67ebb2073a0b74bd37a431ed93ebba510c1b6896c0793)"
SRC="$IEC_THIRDPARTY/vim-$VIM_VER"
BLD="$IEC_ROOT/build/vim"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
RESDIR="$IEC_ROOT/platform/ohos/har/src/main/resources/rawfile/tools"
SHIM_B="$IEC_ROOT/build/extra-cmds"
NC="$IEC_ROOT/build/python/deps"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

[ -f "$NC/lib/libncursesw.a" ] || iec_err "missing $NC/lib/libncursesw.a (run scripts/optional/build_python.sh first)"
mkdir -p "$BLD" "$OUT_DIR" "$RESDIR" "$IEC_THIRDPARTY"
iec_fetch_verified "https://codeload.github.com/vim/vim/tar.gz/$VIM_COMMIT" \
	"$TAR" "$SHA256" "vim $VIM_VER"
if [ ! -f "$SRC/src/configure" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

if [ ! -f "$SRC/src/auto/config.mk" ]; then
	( cd "$SRC" && ./configure \
		--host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
		--prefix="$IEC_ROOT/build/vim-prefix" \
		--with-features=small --disable-gui --without-x --disable-nls \
		--enable-terminal --enable-multibyte --with-tlib=ncursesw \
		CC="$CC_TARGET" CFLAGS="-O2 -fPIC -I$NC/include -I$NC/include/ncursesw" \
		LDFLAGS="-L$NC/lib" > "$IEC_ROOT/build/vim-configure.log" 2>&1 ) \
		|| { tail -40 "$IEC_ROOT/build/vim-configure.log" >&2; iec_err "vim configure failed"; }
fi

# Vim's configure runs on the build host and therefore adds macOS-specific
# pieces even for a cross target.  Strip them when building on Darwin.
if [ "$(uname -s)" = "Darwin" ]; then
	perl -pi -e 's/^CPPFLAGS\s*=.*-DMACOS_X.*/CPPFLAGS\t=/' "$SRC/src/auto/config.mk"
	perl -pi -e 's/ -framework CoreServices//' "$SRC/src/auto/config.mk"
	perl -pi -e 's/^OS_EXTRA_SRC\s*=.*/OS_EXTRA_SRC\t=/' "$SRC/src/auto/config.mk"
	perl -pi -e 's/^OS_EXTRA_OBJ\s*=.*/OS_EXTRA_OBJ\t=/' "$SRC/src/auto/config.mk"
	python3 - "$SRC/src/auto/osdef.h" <<'PYOSDEF'
import sys
path = sys.argv[1]
lines = []
for line in open(path):
    if any(name in line for name in ('tgetent(', 'tgetnum(', 'tgetflag(', 'tgoto(', 'tputs(')):
        continue
    lines.append(line)
open(path, 'w').writelines(lines)
PYOSDEF
fi

make -C "$SRC/src" -j"$JOBS" > "$IEC_ROOT/build/vim-make.log" 2>&1 \
	|| { tail -40 "$IEC_ROOT/build/vim-make.log" >&2; iec_err "vim build failed"; }

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_vim_main \
	"$SRC/src/objects/main.o" "$BLD/vim_main.o"

declare -a OBJS=()
while IFS= read -r obj; do
	[ "$(basename "$obj")" = "main.o" ] && continue
	OBJS+=("$obj")
done < <(find "$SRC/src/objects" -maxdepth 1 -name '*.o' | sort)

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libvimcmd.so" "$BLD/vim_main.o" "${OBJS[@]}" \
	"$NC/lib/libncursesw.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libvimcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libvimcmd.so" \
	| grep ' iec_vim_main$' >/dev/null || iec_err "vim: entry iec_vim_main is not exported"

# Runtime files (defaults.vim, syntax, ftplugin, ...).  Vim can start without
# them, but a command named "vi" is much less surprising with them present.
tar -czf "$RESDIR/vim-runtime.tar.gz" -C "$SRC" runtime
iec_log "done: $OUT_DIR/libvimcmd.so"
iec_log "done: $RESDIR/vim-runtime.tar.gz"

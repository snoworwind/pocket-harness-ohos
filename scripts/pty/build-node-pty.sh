#!/usr/bin/env bash
# 从源码为鸿蒙 arm64 编译 node-pty 的原生插件（pty.node）。
#
# node-pty 直接调用 libc 的 forkpty/openpty/posix_openpt/execvp。在鸿蒙沙箱里
# /dev/ptmx 不可打开、文本启动器也不能被内核 exec，所以这里把 IEC 的 tty 与 exec
# shim 编进 pty.node，并用 --wrap 把 pty.cc 里的这些调用改到 shim：
#   * forkpty/openpty/posix_openpt → tty shim → 执行服务内置的虚拟 PTY；
#   * execvp → exec shim → 执行服务，与 shell/python 的 exec 走同一条路。
# 没有这一步时 `require('node-pty').spawn()` 报 forkpty(3) failed。
#
#   scripts/pty/build-node-pty.sh
#
# 产物默认写到 /var/tmp/dsh-pty/pty.node，再由打包流程放进引擎归档。
set -euo pipefail
R=${NATIVE_ROOT:-/var/tmp/deepseek-harmony-native}
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=${PTY_SRC:-$R/official-engine/node_modules/node-pty}
NAPIDIR=${NAPI_DIR:-/var/tmp/dsh-require-builtin/napi/node-addon-api}
NODE_SRC=${NODE_SRC:-$R/node-v24.22.1}
# The shims come from the checkout this script belongs to, not from a stale copy
# under NATIVE_ROOT: they change together with the exec/tty services.
IEC_ROOT=${IEC_ROOT:-$REPO_ROOT/native/iec}
OUT=${PTY_OUT:-/var/tmp/dsh-pty}
CXX=${CXX_BIN:-$R/compiler/bin/clang++}
CC=${CC_BIN:-$R/compiler/bin/clang}
SYSROOT=${OHOS_SYSROOT:-$R/sdk/native/sysroot}
SHIM_BUILD="$OUT/shim"
mkdir -p "$OUT" "$SHIM_BUILD"

# The shims are compiled exactly the way the other command objects build them:
# link-time interception, so pty.cc's calls are rewritten to __wrap_<name>.
SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE
  -I "$IEC_ROOT" -I "$IEC_ROOT/common")

"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" "${SHIM_CFLAGS[@]}" \
  -c "$IEC_ROOT/tty/shim.c" -o "$SHIM_BUILD/tty.o"
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" "${SHIM_CFLAGS[@]}" \
  -c "$IEC_ROOT/exec/shim.c" -o "$SHIM_BUILD/exec.o"
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" "${SHIM_CFLAGS[@]}" \
  -c "$IEC_ROOT/common/rpc.c" -o "$SHIM_BUILD/rpc.o"
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" "${SHIM_CFLAGS[@]}" \
  -c "$IEC_ROOT/common/sock_client.c" -o "$SHIM_BUILD/sock_client.o"

WRAPS=(open close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
  tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
  posix_openpt openpty login_tty forkpty
  execve execv execvp execvpe execl execlp execle system popen pclose)
WRAP_FLAGS=()
for name in "${WRAPS[@]}"; do WRAP_FLAGS+=("-Wl,--wrap=$name"); done

"$CXX" --target=aarch64-linux-ohos --sysroot="$SYSROOT" \
  -O2 -fPIC -shared -std=c++17 -pthread \
  -DNAPI_VERSION=9 -DNAPI_CPP_EXCEPTIONS -DNODE_ADDON_API_DISABLE_DEPRECATED \
  -I "$NAPIDIR" -I "$NODE_SRC/src" -I "$NODE_SRC/deps/v8/include" \
  -o "$OUT/pty.node" "$SRC/src/unix/pty.cc" \
  "$SHIM_BUILD/tty.o" "$SHIM_BUILD/exec.o" "$SHIM_BUILD/rpc.o" "$SHIM_BUILD/sock_client.o" \
  -Wl,-Bsymbolic-functions -Wl,-z,now "${WRAP_FLAGS[@]}" -lutil

echo '=== 产物 ==='
"$R/sdk/native/llvm/bin/llvm-readelf" -h "$OUT/pty.node" | grep -E 'Class|Machine|Type'
"$R/sdk/native/llvm/bin/llvm-readelf" -d "$OUT/pty.node" | grep NEEDED
"$R/sdk/native/llvm/bin/llvm-nm" -D --defined-only "$OUT/pty.node" | grep -E 'napi_register_module|napi_module' | head -3
echo '=== pty 调用是否已落到 shim（期望 __wrap_* 定义、无 U forkpty/openpty） ==='
"$R/sdk/native/llvm/bin/llvm-nm" -D "$OUT/pty.node" | grep -E '(__wrap_)?(forkpty|openpty|posix_openpt|execvp)$' || true
echo "size: $(stat -c%s "$OUT/pty.node")"

# The engine archive is assembled from addon-stage, which is where the original
# prebuilt pty.node lives. Update it in place when this tree has one, so the next
# pack-native.sh run ships the rebuilt plugin.
ADDON_PTY="$R/addon-stage/node_modules/node-pty/build/Release/pty.node"
if [ -f "$ADDON_PTY" ]; then
  cp -f "$OUT/pty.node" "$ADDON_PTY"
  echo "installed: $ADDON_PTY"
fi

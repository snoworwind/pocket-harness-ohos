#!/usr/bin/env bash
# 从源码为鸿蒙 arm64 编译 node-pty 的原生插件（pty.node）。
set -euo pipefail
R=/var/tmp/deepseek-harmony-native
SRC="$R/official-engine/node_modules/node-pty"
NAPI=/var/tmp/dsh-require-builtin/napi/node-addon-api
NODE_SRC="$R/node-v24.22.1"
OUT=${PTY_OUT:-/var/tmp/dsh-pty}
CXX="$R/compiler/bin/clang++"
mkdir -p "$OUT"

"$CXX" --target=aarch64-linux-ohos --sysroot="$R/sdk/native/sysroot" \
  -O2 -fPIC -shared -std=c++17 -pthread \
  -DNAPI_VERSION=9 -DNAPI_CPP_EXCEPTIONS -DNODE_ADDON_API_DISABLE_DEPRECATED \
  -I "$NAPI" -I "$NODE_SRC/src" -I "$NODE_SRC/deps/v8/include" \
  -o "$OUT/pty.node" "$SRC/src/unix/pty.cc" -lutil

echo '=== 产物 ==='
"$R/sdk/native/llvm/bin/llvm-readelf" -h "$OUT/pty.node" | grep -E 'Class|Machine|Type'
"$R/sdk/native/llvm/bin/llvm-readelf" -d "$OUT/pty.node" | grep NEEDED
"$R/sdk/native/llvm/bin/llvm-nm" -D --defined-only "$OUT/pty.node" | grep -E 'napi_register_module|napi_module' | head -3
"$R/sdk/native/llvm/bin/llvm-nm" -D -u "$OUT/pty.node" | grep -E 'forkpty|openpty|login_tty' | head -5
echo "size: $(stat -c%s "$OUT/pty.node")"

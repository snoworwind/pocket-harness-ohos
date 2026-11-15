#!/usr/bin/env bash
# 为鸿蒙 arm64 编译官方引擎需要的两个原生插件，并摆成引擎运行时会找的目录结构。
#
#   bash native/toolchain/build-addons.sh
#
# 输入（可覆盖）：
#   NATIVE_ROOT  交叉编译根目录，默认 /var/tmp/deepseek-harmony-native
#   ADDON_SRC    上游源码，默认 /var/tmp/dsh-require-builtin（repo 与 node-addon-api 在其下）
# 输出：
#   $ADDON_STAGE 里的 node_modules 片段，pack-native.sh 会把它叠加到引擎树
#
# 说明：两个插件都只依赖 Node-API（NAPI_VERSION=9），符号在运行时由 libnode.so 提供。
set -euo pipefail

NATIVE_ROOT="${NATIVE_ROOT:-/var/tmp/deepseek-harmony-native}"
ADDON_SRC="${ADDON_SRC:-/var/tmp/dsh-require-builtin}"
ADDON_STAGE="${ADDON_STAGE:-$NATIVE_ROOT/addon-stage}"
SYSTEM_PKG="$NATIVE_ROOT/official-engine/node_modules/@deepseek-ai/node-addon-system"
NODE_SRC="$NATIVE_ROOT/node-v24.22.1"
CC="$NATIVE_ROOT/compiler/bin/clang"
CXX="$NATIVE_ROOT/compiler/bin/clang++"
SYSROOT="$NATIVE_ROOT/sdk/native/sysroot"
REPO="$ADDON_SRC/repo"
NAPI_API="$ADDON_SRC/napi/node-addon-api"
TARGET="--target=${TARGET:-aarch64-linux-ohos}"
ADDON_ARCH="${ADDON_ARCH:-arm64}"

for tool in "$CC" "$CXX" "$NODE_SRC/src/node_api.h" "$SYSTEM_PKG/src/flock.c" "$REPO/packages/native/binding.gyp" "$NAPI_API/napi.h"; do
  [ -e "$tool" ] || { echo "build-addons: 缺少 $tool" >&2; exit 1; }
done

rm -rf "$ADDON_STAGE"
mkdir -p "$ADDON_STAGE"
BUILD="$ADDON_STAGE/.build"
mkdir -p "$BUILD/obj"

echo '=== flock（@deepseek-ai/node-addon-system）==='
"$CC" $TARGET --sysroot="$SYSROOT" -O2 -fPIC -shared -D_GNU_SOURCE -DNAPI_VERSION=9 \
  -I "$NODE_SRC/src" -o "$BUILD/system.node" "$SYSTEM_PKG/src/flock.c"
echo "system.node $(stat -c%s "$BUILD/system.node") 字节"

echo '=== require_builtin（node-addon-require-builtin）==='
SOURCES=(
  node_api_addon.cc debug_trace.cc native_types.cc runtime_symbol.cc
  runtime_context/helper.cc runtime_context/platform.cc
  runtime_context/darwin_arm64.cc runtime_context/darwin_x64.cc
  runtime_context/linux_arm64.cc runtime_context/linux_x64.cc
  runtime_context/win32_arm64.cc runtime_context/win32_x64.cc runtime_context/win32_ia32.cc
  runtime_probe/helper.cc runtime_probe/platform.cc runtime_probe/getter_decoder.cc
  runtime_probe/posix.cc runtime_probe/win32_common.cc
  runtime_probe/darwin_arm64.cc runtime_probe/darwin_x64.cc
  runtime_probe/linux_arm64.cc runtime_probe/linux_x64.cc
  runtime_probe/win32_arm64.cc runtime_probe/win32_x64.cc runtime_probe/win32_ia32.cc
  require_builtin_probe.cc
  runtime_context/embedder_data.cc runtime_context/runtime_profile.cc
  runtime_context/runtime_profile_napi.cc runtime_compat_napi.cc
)
for rel in "${SOURCES[@]}"; do
  "$CXX" $TARGET --sysroot="$SYSROOT" -O2 -fPIC -fno-exceptions -fvisibility=hidden -std=c++17 \
    -DNAPI_VERSION=9 -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS -DNARB_BACKEND=1 -DNARB_PRODUCT=1 \
    -I "$REPO/packages/native/src" -I "$NAPI_API" -I "$NODE_SRC/src" -I "$NODE_SRC/deps/v8/include" \
    -c "$REPO/packages/native/src/$rel" -o "$BUILD/obj/${rel//\//_}.o"
done
"$CXX" $TARGET --sysroot="$SYSROOT" -shared -fPIC -o "$BUILD/require_builtin.node" "$BUILD"/obj/*.o
echo "require_builtin.node $(stat -c%s "$BUILD/require_builtin.node") 字节"
# 产品号必须是 require-builtin（1）：引擎加载时会校验，编成 internal-loader（2）会报
# "native binding product mismatch ... expected require-builtin, got internal-loader"。
# 注意用命令替换而不是管道 + grep -q：set -o pipefail 下 strings 会因为 SIGPIPE 判失败。
product_strings="$(strings "$BUILD/require_builtin.node")"
case "$product_strings" in
  *require-builtin*) ;;
  *) echo 'build-addons: require_builtin.node 的产品号不是 require-builtin' >&2; exit 1 ;;
esac
case "$product_strings" in
  *internal-loader*) echo 'build-addons: require_builtin.node 被编成了 internal-loader' >&2; exit 1 ;;
  *) ;;
esac

echo '=== node-pty（交互式终端）==='
PTY_SRC="$NATIVE_ROOT/official-engine/node_modules/node-pty"
"$CXX" $TARGET --sysroot="$SYSROOT" -O2 -fPIC -shared -std=c++17 -pthread \
  -DNAPI_VERSION=9 -DNAPI_CPP_EXCEPTIONS \
  -I "$NAPI_API" -I "$NODE_SRC/src" -I "$NODE_SRC/deps/v8/include" \
  -o "$BUILD/pty.node" "$PTY_SRC/src/unix/pty.cc" -lutil
echo "pty.node $(stat -c%s "$BUILD/pty.node") 字节"

# 运行时会按 napi-v9 + 平台后缀找本地构建产物，gnu/musl 两套都放一份。
for libc in musl gnu; do
  RB_DIR="$ADDON_STAGE/node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-$ADDON_ARCH-$libc"
  mkdir -p "$RB_DIR"
  cp "$BUILD/require_builtin.node" "$RB_DIR/require_builtin.node"

  SYS_DIR="$ADDON_STAGE/node_modules/@deepseek-ai/node-addon-system-linux-$ADDON_ARCH"
  mkdir -p "$SYS_DIR/bin/$libc"
  cp "$BUILD/system.node" "$SYS_DIR/bin/$libc/system.node"
done

# node-pty 的加载器只看 build/Release/pty.node。
mkdir -p "$ADDON_STAGE/node_modules/node-pty/build/Release"
cp "$BUILD/pty.node" "$ADDON_STAGE/node_modules/node-pty/build/Release/pty.node"

cat > "$ADDON_STAGE/node_modules/@deepseek-ai/node-addon-system-linux-$ADDON_ARCH/package.json" <<EOF
{
  "name": "@deepseek-ai/node-addon-system-linux-$ADDON_ARCH",  "version": "0.1.2",
  "description": "HarmonyOS arm64 build of the DSH system primitives (flock).",
  "os": ["linux"],
  "cpu": ["$ADDON_ARCH"],
  "license": "BSD-3-Clause"
}
EOF

echo '=== 结果 ==='
find "$ADDON_STAGE/node_modules" -name '*.node' -o -name 'package.json' | sed "s|$ADDON_STAGE/||"
echo "ADDONS_READY $ADDON_STAGE"

#!/bin/bash
# 最终版 libnode.so 重建：
#   头文件 = libc++ 22（有 std::ranges / std::views，V8 需要）
#   ABI 命名空间 = __n1（与随 HAP 打包的 libc++_shared.so 一致）
#
# 为什么不是 SDK 自带的 libcxx-ohos 头文件：那套没有 <ranges>，V8 编不过；
# 而 llvm22 / ndk-cxx 的 __1 头文件产物在真机上 dlopen 会缺 __n1 符号。
# 复制 llvm22 头文件、把 __config_site 的命名空间改成 __n1 后，
# scripts/probe-ranges-n1.sh 已验证：ranges 代码可编译，且 -z defs 链接随包
# libc++_shared.so 全部符号解析。
set -euo pipefail
ROOT=/var/tmp/deepseek-harmony-native
H="$ROOT/libcxx22-n1/include/c++/v1"

echo '== 1. 准备 libc++22 + __n1 头文件 =='
rm -rf "$ROOT/libcxx22-n1"
mkdir -p "$(dirname "$H")"
cp -r "$ROOT/llvm22/usr/include/c++/v1/." "$H/"
sed -i 's/^#define _LIBCPP_ABI_NAMESPACE __1$/#define _LIBCPP_ABI_NAMESPACE __n1/' "$H/__config_site"
grep -m1 '_LIBCPP_ABI_NAMESPACE' "$H/__config_site"

echo '== 2. 复原 V8 源码（之前为旧头文件做的等价改写不再需要）=='
mkdir -p "$ROOT/.revert-v8"
tar -xzf "$ROOT/downloads/node-v24.22.1.tar.gz" -C "$ROOT/.revert-v8" \
  node-v24.22.1/deps/v8/src/objects/descriptor-array-inl.h \
  node-v24.22.1/deps/v8/src/objects/transitions-inl.h
cp -f "$ROOT/.revert-v8/node-v24.22.1/deps/v8/src/objects/descriptor-array-inl.h" \
  "$ROOT/node-v24.22.1/deps/v8/src/objects/descriptor-array-inl.h"
cp -f "$ROOT/.revert-v8/node-v24.22.1/deps/v8/src/objects/transitions-inl.h" \
  "$ROOT/node-v24.22.1/deps/v8/src/objects/transitions-inl.h"
grep -c 'std::ranges::lower_bound' "$ROOT/node-v24.22.1/deps/v8/src/objects/descriptor-array-inl.h"

echo '== 3. 改写编译器包装 =='
cat > "$ROOT/compiler/bin/clang++" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu"
exec "$ROOT/llvm22/usr/bin/clang++-22" -resource-dir="$ROOT/llvm22/usr/lib/clang/22" -stdlib=libc++ -nostdinc++ -isystem "$H" -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -L"$ROOT/ndk-cxx/lib/aarch64-linux-ohos" -L"$ROOT/sdk/native/llvm/lib/aarch64-linux-ohos" "\$@"
EOF
chmod +x "$ROOT/compiler/bin/clang++"

echo '== 4. 清掉旧 Release 并全量重编 =='
rm -rf "$ROOT/node-v24.22.1/out/Release"
export OHOS_SDK="$ROOT/sdk"
export CLANG="$ROOT/compiler/bin/clang" CLANG_DIR="$ROOT/compiler/bin" CLANGXX="$ROOT/compiler/bin/clang++"
export HOST_CC=gcc HOST_CXX=g++ HOST_AR=ar HOST_NM=nm HOST_READELF=readelf
export JOBS=8
export IEC_NODE_SRC="$ROOT/node-v24.22.1"
export IEC_NODE_TARBALL="$ROOT/downloads/node-v24.22.1.tar.gz"
export IEC_NODE_BUILD="$ROOT/iec/build/node24"
bash "$ROOT/iec/scripts/optional/build_node.sh" all > "$ROOT/logs/node24-ranges.log" 2>&1

echo '== 5. 结果 =='
L="$ROOT/iec/platform/ohos/har/libs/arm64-v8a/libnode.so"
ls -l "$L"
echo "  std::__1  undef: $(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt3__1')"
echo "  std::__n1 undef: $(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt4__n1')"

#!/bin/bash
# 只跑 libnode 的构建阶段（ninja 已是 no-op，主要是重链接），把
# libcxx_abi_compat.o 接进去，补随包 libc++_shared 缺的 std::__n1::__hash_memory。
set -euo pipefail
ROOT=/var/tmp/deepseek-harmony-native
export OHOS_SDK="$ROOT/sdk"
export CLANG="$ROOT/compiler/bin/clang" CLANG_DIR="$ROOT/compiler/bin" CLANGXX="$ROOT/compiler/bin/clang++"
export HOST_CC=gcc HOST_CXX=g++ HOST_AR=ar HOST_NM=nm HOST_READELF=readelf
export JOBS=8
export IEC_NODE_SRC="$ROOT/node-v24.22.1"
export IEC_NODE_TARBALL="$ROOT/downloads/node-v24.22.1.tar.gz"
export IEC_NODE_BUILD="$ROOT/iec/build/node24"
bash "$ROOT/iec/scripts/optional/build_node.sh" build > "$ROOT/logs/node24-relink.log" 2>&1
L="$ROOT/iec/platform/ohos/har/libs/arm64-v8a/libnode.so"
ls -l "$L"
echo "  __hash_memory defined in libnode: $(nm -D --defined-only "$L" | grep -c '__hash_memory')"

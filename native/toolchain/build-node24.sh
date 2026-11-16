#!/usr/bin/env bash
set -euo pipefail
ROOT=${NATIVE_BASE:-/var/tmp/deepseek-harmony-native}
PROJECT=${PROJECT:-"$(cd "$(dirname "$0")/../.." && pwd)"}
while [ ! -x "$ROOT/sdk/native/llvm/bin/clang" ]; do sleep 2; done
mkdir -p "$ROOT/iec" "$ROOT/compiler/bin" "$ROOT/logs"
if [ ! -f "$ROOT/iec/scripts/optional/build_node.sh" ]; then
  (cd "$PROJECT/native/iec" && tar --exclude=build --exclude=thirdparty/node* -cf - .) | (cd "$ROOT/iec" && tar -xf -)
fi
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
RESOURCE="$ROOT/llvm22/usr/lib/clang/22"
# libc++ 头文件必须是 libc++ 22（V8 需要 std::ranges / std::views），但 ABI 命名空间
# 要改成 __n1 —— 这是随 HAP 打包的 libc++_shared.so 导出的那一个。SDK 自带的
# libcxx-ohos 头文件虽然是 __n1，却没有 <ranges>；llvm22 / ndk-cxx 的默认 __1 则会在
# 真机 dlopen 时报 "_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found"。
# 组合验证见 scripts/probe-ranges-n1.sh。
H="$ROOT/libcxx22-n1/include/c++/v1"
rm -rf "$ROOT/libcxx22-n1"
mkdir -p "$(dirname "$H")"
cp -r "$ROOT/llvm22/usr/include/c++/v1/." "$H/"
sed -i 's/^#define _LIBCPP_ABI_NAMESPACE __1$/#define _LIBCPP_ABI_NAMESPACE __n1/' "$H/__config_site"
grep -m1 '_LIBCPP_ABI_NAMESPACE' "$H/__config_site"
cat > "$ROOT/compiler/bin/clang" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu"
exec "$ROOT/llvm22/usr/bin/clang-22" -resource-dir="$RESOURCE" -L"$ROOT/sdk/native/llvm/lib/aarch64-linux-ohos" "\$@"
EOF
cat > "$ROOT/compiler/bin/clang++" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu"
exec "$ROOT/llvm22/usr/bin/clang++-22" -resource-dir="$RESOURCE" -stdlib=libc++ -nostdinc++ -isystem "$H" -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -L"$ROOT/ndk-cxx/lib/aarch64-linux-ohos" -L"$ROOT/sdk/native/llvm/lib/aarch64-linux-ohos" "\$@"
EOF
chmod +x "$ROOT/compiler/bin/clang" "$ROOT/compiler/bin/clang++"
for tool in llvm-ar llvm-ranlib llvm-nm llvm-readelf llvm-objcopy llvm-strip ld.lld; do ln -sfn "$ROOT/sdk/native/llvm/bin/$tool" "$ROOT/compiler/bin/$tool"; done
export OHOS_SDK="$ROOT/sdk"
export CLANG="$ROOT/compiler/bin/clang" CLANG_DIR="$ROOT/compiler/bin" CLANGXX="$ROOT/compiler/bin/clang++"
export HOST_CC=gcc HOST_CXX=g++ HOST_AR=ar HOST_NM=nm HOST_READELF=readelf
export JOBS=8
export IEC_NODE_SRC="$ROOT/node-v24.22.1" IEC_NODE_TARBALL="$ROOT/downloads/node-v24.22.1.tar.gz"
export IEC_NODE_BUILD="$ROOT/iec/build/node24"
NODE_SHA=$(grep ' node-v24.22.1.tar.gz$' "$ROOT/downloads/SHASUMS256.txt" | cut -d' ' -f1)
python3 - "$ROOT/iec/scripts/optional/build_node.sh" "$NODE_SHA" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('NODE_VER="v22.19.0"','NODE_VER="v24.22.1"').replace('4cea680423f98abc6a2a5ca127fb34c5f6586c24217f57749be6ea886c9be9a6',sys.argv[2])
open(p,'w').write(s)
PY
python3 - "$ROOT/iec/scripts/optional/node-ohos/iec_node_entry.cc" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('parts.push_back("--no-expose-wasm");','parts.push_back("--wasm-jitless");')
open(p,'w').write(s)
PY
# 注意：scripts/patch-v8-drumbrake.sh 是实验性的。当前 V8 快照里的 DrumBrake
# 源码落后于 V8 的 API（50 处编译错误），打开后无法通过编译，因此默认不启用。
"$CLANG" --target=aarch64-linux-ohos --sysroot="$OHOS_SDK/native/sysroot" -v -x c -o "$ROOT/probe.so" -shared - <<< 'int main(void){return 0;}' > "$ROOT/logs/compiler-probe.log" 2>&1
bash "$ROOT/iec/scripts/optional/build_node.sh" "${1:-build}" > "$ROOT/logs/node24.log" 2>&1
echo NODE24_BUILD_COMPLETE

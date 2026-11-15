#!/bin/bash
# 验证：用 SDK 的 libcxx-ohos 头文件（ABI 命名空间 __n1）编译并链接随包
# libc++_shared.so，符号必须能全部解析——这是修 libnode.so 报
# "_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found" 的前提。
set -u
export LD_LIBRARY_PATH=/var/tmp/deepseek-harmony-native/llvm22/usr/lib/x86_64-linux-gnu
W=/var/tmp/libcxx-n1-probe
mkdir -p "$W"
cat > "$W/probe.cc" <<'SRC'
#include <memory>
#include <string>
#include <stdexcept>
std::string f(std::string const& s) { return s + std::string("x"); }
std::shared_ptr<int> g() { return std::make_shared<int>(1); }
void h() { throw std::runtime_error("x"); }
SRC
CLANG=/var/tmp/deepseek-harmony-native/llvm22/usr/bin/clang-22
RES=/var/tmp/deepseek-harmony-native/llvm22/usr/lib/clang/22
HDRS=$(ls -d '/mnt/d/D Program Files/DevEco Studio/sdk/default/openharmony/native/llvm/include/libcxx-ohos/include/c++/v1')
LIB=/var/tmp/deepseek-harmony-native/ndk-cxx/lib/aarch64-linux-ohos
"$CLANG" -resource-dir="$RES" --target=aarch64-linux-ohos \
  --sysroot=/var/tmp/deepseek-harmony-native/sdk/native/sysroot \
  -stdlib=libc++ -nostdinc++ -isystem "$HDRS" \
  -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \
  -fPIC -shared "$W/probe.cc" -o "$W/probe.so" \
  -L"$LIB" -lc++_shared -Wl,-rpath-link,"$LIB" -Wl,-z,defs 2>"$W/err.txt" \
  || { echo 'link failed'; head -20 "$W/err.txt"; exit 1; }
echo 'link ok with libc++_shared.so'
echo "  std::__1  refs: $(nm -D -u "$W/probe.so" | grep -c '_ZNSt3__1')"
echo "  std::__n1 refs: $(nm -D -u "$W/probe.so" | grep -c '_ZNSt4__n1')"
echo "  NEEDED: $(readelf -d "$W/probe.so" | grep NEEDED | tr -s ' ' | cut -d'[' -f2 | cut -d']' -f1 | tr '\n' ' ')"

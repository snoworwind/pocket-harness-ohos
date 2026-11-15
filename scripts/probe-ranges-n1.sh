#!/bin/bash
# 试验：用 libc++ 22 的头文件（有 std::ranges / std::views），把 ABI 命名空间改成
# __n1 以匹配随包 libc++_shared.so，编译一个用范围库的 probe 并 -z defs 链接。
# 目的是判断「新头 + 旧命名空间」这条路能不能替代逐个改写 V8 的 ranges 用法。
set -u
export LD_LIBRARY_PATH=/var/tmp/deepseek-harmony-native/llvm22/usr/lib/x86_64-linux-gnu
ROOT=/var/tmp/deepseek-harmony-native
H="$ROOT/libcxx22-n1/include/c++/v1"
W=/var/tmp/probe-ranges
mkdir -p "$W"

echo '== 1. 复制并改写 __config_site =='
rm -rf "$ROOT/libcxx22-n1"
mkdir -p "$(dirname "$H")"
cp -r "$ROOT/llvm22/usr/include/c++/v1/." "$H/"
sed -i 's/^#define _LIBCPP_ABI_NAMESPACE __1$/#define _LIBCPP_ABI_NAMESPACE __n1/' "$H/__config_site"
grep -m1 '_LIBCPP_ABI_NAMESPACE' "$H/__config_site"

cat > "$W/probe.cc" <<'SRC'
#include <algorithm>
#include <memory>
#include <ranges>
#include <string>
#include <string_view>
#include <vector>
#include <map>

std::string join(std::vector<std::string> const& v) {
  std::string out;
  for (auto const& s : v) out += s;
  return out;
}

std::vector<std::string> split(std::string const& s, char sep) {
  std::vector<std::string> out;
  for (auto part : std::views::split(s, sep)) out.emplace_back(part.begin(), part.end());
  return out;
}

std::shared_ptr<int> make() { return std::make_shared<int>(7); }

std::string sorted(std::map<std::string, int> const& m) {
  std::vector<std::string> keys;
  for (auto const& [k, v] : m) keys.push_back(k);
  std::ranges::sort(keys);
  return join(keys);
}
SRC

echo '== 2. 编译 + 链接（-z defs 要求符号全部解析）=='
CLANG="$ROOT/llvm22/usr/bin/clang-22"
"$CLANG" -resource-dir="$ROOT/llvm22/usr/lib/clang/22" --target=aarch64-linux-ohos \
  --sysroot="$ROOT/sdk/native/sysroot" -stdlib=libc++ -nostdinc++ -isystem "$H" \
  -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \
  -std=c++20 -fPIC -shared "$W/probe.cc" -o "$W/probe.so" \
  -L"$ROOT/ndk-cxx/lib/aarch64-linux-ohos" -lc++_shared \
  -Wl,-rpath-link,"$ROOT/ndk-cxx/lib/aarch64-linux-ohos" -Wl,-z,defs 2> "$W/err.txt"
rc=$?
if [ $rc -ne 0 ]; then
  echo "LINK FAILED (rc=$rc)"
  grep -E "undefined|error" "$W/err.txt" | head -12
  exit 0
fi
echo 'LINK OK'
echo "  std::__1  refs: $(nm -D -u "$W/probe.so" | grep -c '_ZNSt3__1')"
echo "  std::__n1 refs: $(nm -D -u "$W/probe.so" | grep -c '_ZNSt4__n1')"
readelf -d "$W/probe.so" | grep NEEDED

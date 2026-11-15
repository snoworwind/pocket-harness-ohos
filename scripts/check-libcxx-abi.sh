#!/bin/bash
# 对比 DevEco SDK 与本地 toolchain 里的 libc++_shared.so，确认随包的那个到底是哪一份。
set -u
A='/mnt/d/D Program Files/DevEco Studio/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so'
B=/var/tmp/deepseek-harmony-native/toolchain/clang_linux-x86_64-02fbe8-20260908/lib/aarch64-linux-ohos/libc++_shared.so
C=/var/tmp/deepseek-harmony-native/ndk-cxx/lib/aarch64-linux-ohos/libc++_shared.so
D='/mnt/d/forGithub/deepseek-harmony/entry/build/default/intermediates/libs/default/arm64-v8a/libc++_shared.so'

for f in "$A" "$B" "$C" "$D"; do
  if [ ! -f "$f" ]; then echo "$f : (missing)"; continue; fi
  echo "$f"
  echo "  size=$(stat -c%s "$f") sha=$(sha256sum "$f" | cut -c1-16)"
  echo "  std::__1=$(nm -D --defined-only "$f" 2>/dev/null | grep -c '_ZNSt3__1') std::__n1=$(nm -D --defined-only "$f" 2>/dev/null | grep -c '_ZNSt4__n1') std::__h=$(nm -D --defined-only "$f" 2>/dev/null | grep -c '_ZNSt2__h')"
done

echo
echo '== HAP 里那份 =='
find /var/tmp -maxdepth 3 -name 'libc++_shared.so' -newer /var/tmp/deepseek-harmony-native/iec 2>/dev/null | head -5

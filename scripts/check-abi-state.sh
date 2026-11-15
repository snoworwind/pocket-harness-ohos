#!/bin/bash
# 检查随包的原生插件与 libnode 引用的 libc++ ABI 命名空间是否与 SDK 的
# libc++_shared.so（std::__n1）一致。
set -u
echo '== addons =='
for f in /var/tmp/deepseek-harmony-native/addon-stage/.build/*.node; do
  [ -f "$f" ] || continue
  a=$(nm -D -u "$f" 2>/dev/null | grep -c '_ZNSt3__1')
  b=$(nm -D -u "$f" 2>/dev/null | grep -c '_ZNSt4__n1')
  echo "$(basename "$f")  __1=$a  __n1=$b"
done
echo
echo '== libnode =='
L=/var/tmp/deepseek-harmony-native/iec/platform/ohos/har/libs/arm64-v8a/libnode.so
if [ -f "$L" ]; then
  echo "size=$(stat -c%s "$L")  __1=$(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt3__1')  __n1=$(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt4__n1')"
fi

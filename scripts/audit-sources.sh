#!/usr/bin/env bash
# 审计 HAP 里随包分发的二进制与归档，确认来源都是本机构建或官方 SDK。
set -u
P=/mnt/d/forGithub/deepseek-harmony
HAP="$P/entry/build/default/outputs/default/entry-default-unsigned.hap"
WA=/var/tmp/deepseek-harmony-audit
rm -rf "$WA"; mkdir -p "$WA"
unzip -q "$HAP" -d "$WA" || { echo "HAP 解包失败" >&2; exit 1; }

echo '=== 1. HAP 内的二进制 ==='
find "$WA/libs" -name '*.so*' -printf '%f %s\n' 2>/dev/null | sort

echo
echo '=== 2. 预期集合核对 ==='
EXPECTED='libnode.so libbash.so libtoybox.so libbsdtar.so libbsdcpio.so libbsdunzip.so libzipcmd.so librg.so libarchive.so.13 libgit.so libgit-remote-http.so libiec_server.so libncploader.so libdsh_terminal.so libc++_shared.so'
for name in $EXPECTED; do
  if [ -f "$WA/libs/arm64-v8a/$name" ]; then echo "ok   $name"; else echo "MISS $name"; fi
done
ACTUAL=$(find "$WA/libs/arm64-v8a" -name '*.so*' -printf '%f\n' | sort)
WANT=$(printf '%s\n' $EXPECTED | sort)
EXTRA=$(comm -13 <(echo "$WANT") <(echo "$ACTUAL"))
MISSING=$(comm -23 <(echo "$WANT") <(echo "$ACTUAL"))
[ -z "$MISSING" ] || echo "缺少：$MISSING"
[ -z "$EXTRA" ] && echo '无额外 .so' || echo "额外 .so：$EXTRA"

echo
echo '=== 3. 引擎归档内的原生插件 ==='
tar -tzf "$WA/resources/rawfile/tools/official-engine.tar.gz" | grep -E '\.node$|node-addon-system-linux-arm64/package.json' | sed 's/^/  /'

echo
echo '=== 4. npm 归档比对（应为 Node 源码构建产物）==='
REBUILT=/var/tmp/deepseek-harmony-native/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz
sha256sum "$WA/resources/rawfile/tools/npm.tar.gz" "$REBUILT" 2>/dev/null | awk '{print "  "$0}'
if cmp -s "$WA/resources/rawfile/tools/npm.tar.gz" "$REBUILT"; then echo '  npm 与本次构建一致'; else echo '  npm 与本次构建不一致'; fi

echo
echo '=== 5. ELF 架构抽查 ==='
READELF=/var/tmp/deepseek-harmony-native/sdk/native/llvm/bin/llvm-readelf
for so in libnode.so libbash.so libtoybox.so librg.so; do
  printf '  %-14s ' "$so"
  "$READELF" -h "$WA/libs/arm64-v8a/$so" 2>/dev/null | awk '/Machine:/{print $2, $3}'
done

echo
echo '=== 6. 引擎入口与 Manifest ==='
tar -tzf "$WA/resources/rawfile/tools/official-engine.tar.gz" | grep -c 'node_modules/@deepseek-ai/dsh/lib/bin.js' | sed 's/^/  dsh bin.js: /'
grep -c '"name"' "$WA/resources/rawfile/tools/runtime-manifest.json" | sed 's/^/  manifest commands: /'

echo
echo '=== 7. libc++ ABI（必须只引用 std::__n1）==='
for so in libnode.so libarchive.so.13; do
  old=$("$READELF" --dyn-syms -W "$WA/libs/arm64-v8a/$so" 2>/dev/null | grep -c 'UND.*_ZNSt3__1' || true)
  new=$("$READELF" --dyn-syms -W "$WA/libs/arm64-v8a/$so" 2>/dev/null | grep -c 'UND.*_ZNSt4__n1' || true)
  printf '  %-18s std::__1=%s std::__n1=%s\n' "$so" "${old:-0}" "${new:-0}"
done

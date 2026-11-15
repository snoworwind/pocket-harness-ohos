#!/usr/bin/env bash
# 收尾验收：把可离线验证的证据一次性打印出来。
set -u
P=/mnt/d/forGithub/deepseek-harmony
HAP="$P/entry/build/default/outputs/default/entry-default-unsigned.hap"
echo "== HAP =="
ls -la "$HAP" | awk '{printf "  %s bytes\n", $5}'
echo "== manifest =="
grep '"name"' "$P/entry/src/main/resources/rawfile/tools/runtime-manifest.json" | sed 's/^/  /'
echo "== entry/libs =="
ls "$P/entry/libs/arm64-v8a" | sed 's/^/  /'
echo "== engine archive =="
tar -tzf "$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz" | wc -l | awk '{print "  entries:", $1}'
echo "== host tests =="
DEVECO_HOME="/mnt/d/D Program Files/DevEco Studio" /var/tmp/deepseek-harmony-native/host-node/bin/node "$P/scripts/test.cjs" 2>&1 | grep -E '^# (pass|fail)|pass [0-9]+|fail [0-9]+' | tail -3

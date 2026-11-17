#!/usr/bin/env bash
set -u
P="${PROJECT:-$(cd "$(dirname "$0")/.." && pwd)}"
T="$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
echo "entries: $(tar -tzf "$T" | wc -l)"
echo '=== addons in engine archive ==='
tar -tzf "$T" | grep -E 'require_builtin\.node|system\.node|node-addon-system-linux-arm64/package\.json' || echo 'NO_ADDONS'
echo '=== engine entry point ==='
tar -tzf "$T" | grep -c 'node_modules/@deepseek-ai/dsh/lib/bin.js'
echo '=== attachment pure-JS fallback ==='
if tar -xOzf "$T" ./node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js 2>/dev/null \
    | grep -q 'pocket-harness-ohos: attachment pure-JS fallback'; then
  echo PATCHED
else
  echo 'NOT PATCHED（用 scripts/pack-native.sh 重新打包）'
  exit 1
fi
echo '=== manifest ==='
cat "$P/entry/src/main/resources/rawfile/tools/runtime-manifest.json" | head -6

#!/usr/bin/env bash
set -euo pipefail
ROOT=/var/tmp/deepseek-harmony-native
cp /mnt/c/Users/zouha/Documents/Codex/2026-11-15/ca/work/oh-uni-package.json "$ROOT/sdk/native/oh-uni-package.json"
export OHOS_SDK="$ROOT/sdk" JOBS=4 IEC_ROOT="$ROOT/iec"
cd "$IEC_ROOT"
echo "BUILD_BEGIN pcre2"
bash scripts/optional/build_pcre2.sh > "$ROOT/logs/pcre2.log" 2>&1 && echo "BUILD_COMPLETE pcre2" || { echo "BUILD_FAILED pcre2"; tail -20 "$ROOT/logs/pcre2.log"; exit 1; }

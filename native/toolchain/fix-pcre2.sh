#!/usr/bin/env bash
# 一次性脚本：确认构建根的 SDK 清单存在，然后编译 pcre2。
# 需要先准备好 $ROOT/sdk（OHOS Linux SDK，含 native/oh-uni-package.json）。
set -euo pipefail
ROOT=${NATIVE_BASE:-/var/tmp/deepseek-harmony-native}
if [ ! -f "$ROOT/sdk/native/oh-uni-package.json" ]; then
  echo "缺少 $ROOT/sdk/native/oh-uni-package.json（从 OHOS SDK 复制后重试）" >&2
  exit 1
fi
export OHOS_SDK="$ROOT/sdk" JOBS=${JOBS:-4} IEC_ROOT="$ROOT/iec"
cd "$IEC_ROOT"
echo "BUILD_BEGIN pcre2"
bash scripts/optional/build_pcre2.sh > "$ROOT/logs/pcre2.log" 2>&1 && echo "BUILD_COMPLETE pcre2" || { echo "BUILD_FAILED pcre2"; tail -20 "$ROOT/logs/pcre2.log"; exit 1; }

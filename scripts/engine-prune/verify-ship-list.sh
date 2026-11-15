#!/usr/bin/env bash
# 用候选 ship 清单打一个临时引擎树，并做一次宿主侧 sdk profile 解析验证。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
LIST="$P/scripts/engine-ship-files.txt"
W=/var/tmp/engine-ship-verify
rm -rf "$W"; mkdir -p "$W/tree/node_modules" "$W/home"
tar -C "$R/official-engine/node_modules" -czf "$W/engine.tgz" -T "$LIST" || { echo TAR_FAILED; exit 1; }
echo "tarball: $(stat -c%s "$W/engine.tgz") bytes"
tar -C "$W/tree/node_modules" -xzf "$W/engine.tgz"
export DSH_HOME="$W/home"
export PATH="$R/host-node/bin:$PATH"
cd "$W/tree" || exit 1
"$R/host-node/bin/node" node_modules/@deepseek-ai/dsh/lib/bin.js --profile sdk --dump-config > "$W/dump.yml" 2> "$W/dump.err"
echo "dump exit=$?"
echo "plugin entries: $(grep -c "name: '" "$W/dump.yml")"
echo '=== 解析告警 ==='
grep -c 'cannot resolve\|not found' "$W/dump.err" || true
head -6 "$W/dump.err"

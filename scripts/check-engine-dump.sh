#!/usr/bin/env bash
# 用宿主 Node 验证裁剪后的引擎树能否解析 sdk profile（插件表完整、无缺包）。
# 只跑 --dump-config，不启动 Agent、不加载 OHOS 的 .node 插件。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
W=/var/tmp/engine-dump-check
rm -rf "$W"; mkdir -p "$W/engine" "$W/home"
tar -C "$W/engine" -xzf "$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
export DSH_HOME="$W/home"
export PATH="$R/host-node/bin:$PATH"
NODE="$R/host-node/bin/node"
echo "node: $($NODE -v)"
cd "$W/engine" || exit 1
"$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js --profile sdk --dump-config > "$W/dump.yml" 2> "$W/dump.err"
echo "exit=$?"
echo "dump lines: $(wc -l < "$W/dump.yml")"
echo '=== 前 12 行 ==='
head -12 "$W/dump.yml"
echo '=== 错误输出（截断）==='
head -12 "$W/dump.err"

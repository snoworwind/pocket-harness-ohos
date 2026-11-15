#!/usr/bin/env bash
set -u
E=/var/tmp/deepseek-harmony-native/official-engine/node_modules
P=/mnt/d/forGithub/deepseek-harmony
T="$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
echo '=== 归档里是否带 @vscode/ripgrep ==='
tar -tzf "$T" | grep -c 'node_modules/@vscode/ripgrep' || true
echo '=== 包内容 ==='
ls "$E/@vscode/ripgrep"
echo '=== package.json ==='
head -30 "$E/@vscode/ripgrep/package.json"
echo '=== index.js ==='
head -40 "$E/@vscode/ripgrep/index.js" 2>/dev/null || head -40 "$E/@vscode/ripgrep/lib/index.js" 2>/dev/null
echo '=== 是否在 ship 清单里 ==='
grep -c '@vscode/ripgrep' "$P/scripts/engine-ship-files.txt" || true

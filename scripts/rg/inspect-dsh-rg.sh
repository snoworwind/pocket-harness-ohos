#!/usr/bin/env bash
set -u
E=/var/tmp/deepseek-harmony-native/official-engine/node_modules
echo '=== @vscode ==='
ls "$E/@vscode" 2>/dev/null || echo '（没有 @vscode 目录）
=== fs-search files ==='
find "$E/@deepseek-ai/dsh-tool-fs-search" -name '*.js' | head -5
echo '=== ripgrep 引用 ==='
grep -rn "vscode/ripgrep\|rgPath\|ripgrep" "$E/@deepseek-ai/dsh-tool-fs-search" --include='*.js' | head -12

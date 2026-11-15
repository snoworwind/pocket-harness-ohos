#!/usr/bin/env bash
set -u
E=/var/tmp/deepseek-harmony-native/official-engine/node_modules/node-pty
echo '=== lib files ==='
find "$E/lib" -name '*.js' | head
echo '=== 绑定加载 ==='
grep -rn "prebuilds\|build/Release\|\.node" "$E/lib" | head -12
echo '=== spawn-helper 引用 ==='
grep -rn "spawn-helper\|spawnHelper" "$E/lib" | head -8
echo '=== unixTerminal 关键片段 ==='
grep -n "require(" "$E/lib/unixTerminal.js" | head -10
echo '=== binding.gyp 后半 ==='
sed -n '80,160p' "$E/binding.gyp"

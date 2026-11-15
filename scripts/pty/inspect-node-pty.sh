#!/usr/bin/env bash
set -u
E=/var/tmp/deepseek-harmony-native/official-engine/node_modules/node-pty
echo '=== layout ==='
ls "$E"
echo '=== package.json (selected) ==='
grep -E '"(name|version|main|types|gypfile)"' "$E/package.json"
echo '=== binding.gyp ==='
sed -n '1,80p' "$E/binding.gyp"
echo '=== src ==='
ls "$E/src" "$E/src/unix" 2>/dev/null
echo '=== require native binding points ==='
grep -rn "\.node'\|require(.*pty" "$E/lib" | head -10

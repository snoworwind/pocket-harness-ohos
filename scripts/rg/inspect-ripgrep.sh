#!/usr/bin/env bash
set -u
W=/var/tmp/ripgrep-build
echo '=== workspace crates ==='
ls "$W/src" | head -20
echo '=== workspace members ==='
sed -n '1,60p' "$W/src/Cargo.toml"
echo '=== run() entry ==='
grep -rn 'pub fn run' "$W/src" --include='*.rs' | head -8

#!/usr/bin/env bash
set -u
S=/var/tmp/ripgrep-build/src
echo '=== src root ==='
ls "$S/src" 2>/dev/null
echo '=== lib/bin sections ==='
grep -n '^\[lib\]\|^\[\[bin\]\]\|^name\|^path' "$S/Cargo.toml" | head -20
echo '=== lib.rs public api ==='
if [ -f "$S/src/lib.rs" ]; then head -40 "$S/src/lib.rs"; fi
echo '=== main.rs ==='
if [ -f "$S/src/main.rs" ]; then head -20 "$S/src/main.rs"; fi
echo '=== crates dir ==='
find "$S/crates" -maxdepth 2 -name Cargo.toml | head

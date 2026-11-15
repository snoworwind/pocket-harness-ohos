#!/usr/bin/env bash
set -u
S=/var/tmp/ripgrep-build/src/crates/core
echo '=== head ==='
head -45 "$S/main.rs"
echo '=== tail ==='
tail -45 "$S/main.rs"
echo '=== top-level fns ==='
grep -n '^fn \|^pub fn \|^struct \|^mod ' "$S/main.rs" | head -25

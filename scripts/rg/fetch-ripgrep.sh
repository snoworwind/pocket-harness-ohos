#!/usr/bin/env bash
set -euo pipefail
R=/var/tmp/deepseek-harmony-native
W=/var/tmp/ripgrep-build
mkdir -p "$W"
cd "$W"
if [ ! -f ripgrep.tar.gz ]; then
  curl -fsSL --retry 2 https://crates.io/api/v1/crates/ripgrep/14.1.1/download -o ripgrep.tar.gz
fi
if [ ! -d src ]; then mkdir -p src && tar -xzf ripgrep.tar.gz -C src --strip-components=1; fi
echo '=== layout ==='
ls src | head
echo '=== crates ==='
ls src/crates
echo '=== core crate ==='
sed -n '1,40p' src/crates/core/Cargo.toml
echo '=== lib entry of ripgrep crate ==='
grep -rn 'pub fn run' src/crates/core/src/*.rs | head -5
grep -n '^name' src/crates/core/Cargo.toml

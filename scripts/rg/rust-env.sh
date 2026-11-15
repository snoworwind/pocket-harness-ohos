#!/usr/bin/env bash
set -u
R=/var/tmp/deepseek-harmony-native
export CARGO_HOME="$R/cargo"
export RUSTUP_HOME="$R/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
echo "rustup: $(command -v rustup)"
rustup show 2>&1 | head -12
echo '--- toolchains ---'
ls "$RUSTUP_HOME/toolchains" 2>/dev/null || echo none
echo '--- installed targets ---'
rustup target list --installed 2>&1 | head -5

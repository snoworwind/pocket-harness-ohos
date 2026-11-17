#!/bin/bash
# fetch_go_ohos.sh — build (or verify) the OpenHarmony Go toolchain.
#
# Stock Go's linux/arm64 c-shared output uses the initial-exec TLS model, and
# musl refuses to dlopen such a library:
#
#   Error relocating libghcmd.so: initial-exec TLS resolves to dynamic definition
#
# GOOS=android is not an alternative: its runtime finds the goroutine TLS slot
# through bionic's fixed TP offsets / pthread_key scan, which musl does not
# provide. The working option is an OpenHarmony fork of Go that emits the
# general-dynamic (TLSDESC) model for c-shared libraries:
#
#   https://gitcode.com/Ember5843/go-ohos-1.26
#
# This script clones that fork and builds a host toolchain with the bootstrap Go
# already on PATH. The gh/git-lfs build scripts use it through GO_TOOLCHAIN (or
# GO_OHOS), and the produced .so then loads on device.
#
# Usage:
#   scripts/optional/fetch_go_ohos.sh          # clone + build into build/go-ohos
#   GO_OHOS_SRC=/path/to/go-ohos scripts/optional/fetch_go_ohos.sh   # build a checkout
#
# Output: $IEC_ROOT/build/go-ohos/bin/go (openHarmony fork, go1.26.x)
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

DEST="${GO_OHOS_DEST:-$IEC_ROOT/build/go-ohos}"
SRC="${GO_OHOS_SRC:-$DEST-src}"
REPO="${GO_OHOS_REPO:-https://gitcode.com/Ember5843/go-ohos-1.26.git}"
BOOTSTRAP="${GO_BOOTSTRAP:-$(command -v go || true)}"

if [ -x "$DEST/bin/go" ]; then
	iec_log "OpenHarmony Go toolchain already built: $DEST/bin/go"
	"$DEST/bin/go" version
	exit 0
fi

[ -n "$BOOTSTRAP" ] || iec_err "a bootstrap Go (>=1.24) is required: set GO_BOOTSTRAP=/path/to/go"
BOOTSTRAP_ROOT="$(cd "$(dirname "$BOOTSTRAP")/.." && pwd)"
iec_log "bootstrap Go: $("$BOOTSTRAP" version)"

if [ ! -f "$SRC/src/make.bash" ]; then
	command -v git >/dev/null 2>&1 || iec_err "git is required to clone $REPO"
	iec_log "clone $REPO -> $SRC"
	rm -rf "$SRC"
	git clone --depth=1 "$REPO" "$SRC" \
		|| iec_err "failed to clone $REPO (network?)"
fi

iec_log "build OpenHarmony Go toolchain (make.bash)"
mkdir -p "$IEC_ROOT/build"
( cd "$SRC/src" && \
	GOROOT_BOOTSTRAP="$BOOTSTRAP_ROOT" GOROOT_FINAL="$DEST" \
	PATH="$BOOTSTRAP_ROOT/bin:$PATH" bash make.bash ) \
	> "$IEC_ROOT/build/go-ohos-make.log" 2>&1 \
	|| { tail -30 "$IEC_ROOT/build/go-ohos-make.log" >&2; iec_err "make.bash failed"; }

mkdir -p "$DEST"
# make.bash builds in place under $SRC; copy the tree so GOROOT points at DEST
# and the source checkout can be discarded later.
( cd "$SRC" && tar --exclude=.git -cf - . ) | ( cd "$DEST" && tar -xf - )

[ -x "$DEST/bin/go" ] || iec_err "no $DEST/bin/go after make.bash"
"$DEST/bin/go" version
iec_log "ready: GO_TOOLCHAIN=$DEST/bin/go (or GO_OHOS=$DEST)"

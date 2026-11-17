#!/bin/bash
# build_gitlfs.sh — git-lfs as a Go c-shared IEC command object.
#
# Go's linux/arm64 c-shared target links against the OHOS libc supplied by the
# DevEco clang driver.  A tiny wrapper package exposes commands.Run() as
# iec_gitlfs_main(argc, argv); the launcher in runtime-manifest.json points at it.
#
# Output: platform/ohos/har/libs/arm64-v8a/libgitlfscmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SRC="${GITLFS_SRC:-$IEC_ROOT/thirdparty/git-lfs}"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUT_DIR/libgitlfscmd.so"
WRAP="$SRC/cmd/gitlfsohos"

command -v go >/dev/null 2>&1 || iec_err "Go toolchain is required for git-lfs"
[ -d "$SRC/.git" ] || iec_clone_if_missing "$SRC" "https://github.com/git-lfs/git-lfs.git"

mkdir -p "$WRAP" "$OUT_DIR"
cat > "$WRAP/main.go" <<'GO'
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"os"
	"unsafe"

	"github.com/git-lfs/git-lfs/v3/commands"
)

//export iec_gitlfs_main
func iec_gitlfs_main(argc C.int, argv C.uintptr_t) C.int {
	n := int(argc)
	args := unsafe.Slice((**C.char)(unsafe.Pointer(uintptr(argv))), n)
	os.Args = make([]string, n)
	for i, arg := range args {
		os.Args[i] = C.GoString(arg)
	}
	code := commands.Run()
	commands.Cleanup()
	return C.int(code)
}

func main() {}
GO

( cd "$SRC" && \
	GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
	go build -buildvcs=false -buildmode=c-shared -trimpath \
		-ldflags='-s -w' -o "$OUT" ./cmd/gitlfsohos ) \
	|| iec_err "git-lfs Go build failed"

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT" | grep ' iec_gitlfs_main$' >/dev/null \
	|| iec_err "git-lfs: entry iec_gitlfs_main is not exported"
rm -f "${OUT%.so}.h"
iec_log "done: $OUT ($(du -h "$OUT" | cut -f1))"

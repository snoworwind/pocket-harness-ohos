#!/bin/bash
# build_gh.sh — GitHub CLI as a Go c-shared IEC command object.
#
# ghcmd.Main() returns the process exit code; the wrapper only supplies argv
# from the IEC launcher.  gh lives under cli/cli's module so the internal
# ghcmd package is importable.
#
# Output: platform/ohos/har/libs/arm64-v8a/libghcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SRC="${GH_SRC:-$IEC_ROOT/thirdparty/gh}"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUT_DIR/libghcmd.so"
WRAP="$SRC/cmd/ghohos"

command -v go >/dev/null 2>&1 || iec_err "Go toolchain is required for gh"
[ -d "$SRC/.git" ] || iec_clone_if_missing "$SRC" "https://github.com/cli/cli.git"

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

	"github.com/cli/cli/v2/internal/ghcmd"
)

//export iec_gh_main
func iec_gh_main(argc C.int, argv C.uintptr_t) C.int {
	n := int(argc)
	args := unsafe.Slice((**C.char)(unsafe.Pointer(uintptr(argv))), n)
	os.Args = make([]string, n)
	for i, arg := range args {
		os.Args[i] = C.GoString(arg)
	}
	return C.int(ghcmd.Main())
}

func main() {}
GO

( cd "$SRC" && \
	GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
	go build -buildvcs=false -buildmode=c-shared -trimpath \
		-ldflags='-s -w' -o "$OUT" ./cmd/ghohos ) \
	|| iec_err "gh Go build failed"

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT" | grep ' iec_gh_main$' >/dev/null \
	|| iec_err "gh: entry iec_gh_main is not exported"
rm -f "${OUT%.so}.h"
iec_log "done: $OUT ($(du -h "$OUT" | cut -f1))"

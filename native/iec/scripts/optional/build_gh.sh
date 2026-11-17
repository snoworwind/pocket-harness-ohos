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
# gh 的 go.mod 会随上游升到新 Go；OpenHarmony 工具链基于 go1.26.5，所以固定到
# 最后一个要求 go <= 1.26 的 tag。换 tag 前先确认 `git show <tag>:go.mod`。
GH_REF="${GH_REF:-v2.100.0}"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUT_DIR/libghcmd.so"
WRAP="$SRC/cmd/ghohos"

# 必须用 OpenHarmony Go 工具链（GOOS=openharmony）：stock Go 的 c-shared 产物用
# initial-exec TLS，鸿蒙 musl 会拒绝 dlopen（"initial-exec TLS resolves to dynamic
# definition"，IEC 侧表现为退出码 125）。OpenHarmony 分支默认用 TLSDESC/GD。
# 构建一次：scripts/optional/fetch_go_ohos.sh，然后：
#   GO_TOOLCHAIN=$IEC_ROOT/build/go-ohos/bin/go 或 GO_OHOS=$IEC_ROOT/build/go-ohos
GO_TOOLCHAIN="${GO_TOOLCHAIN:-${GO_OHOS:+$GO_OHOS/bin/go}}"
GO_TOOLCHAIN="${GO_TOOLCHAIN:-go}"
GO_OS="${GO_OS:-openharmony}"

command -v "$GO_TOOLCHAIN" >/dev/null 2>&1 || iec_err "Go toolchain not found: $GO_TOOLCHAIN"
"$GO_TOOLCHAIN" tool dist list 2>/dev/null | grep -qx "$GO_OS/arm64" \
	|| iec_err "Go toolchain $("$GO_TOOLCHAIN" version) has no $GO_OS/arm64 target. Run scripts/optional/fetch_go_ohos.sh and set GO_TOOLCHAIN=<repo>/build/go-ohos/bin/go"
iec_clone_if_missing "$SRC" "https://github.com/cli/cli.git" "$GH_REF"

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
	GOOS="$GO_OS" GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
	"$GO_TOOLCHAIN" build -buildvcs=false -buildmode=c-shared -trimpath \
		-ldflags='-s -w' -o "$OUT" ./cmd/ghohos ) \
	|| iec_err "gh Go build failed"

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT" | grep ' iec_gh_main$' >/dev/null \
	|| iec_err "gh: entry iec_gh_main is not exported"
# Regression guard: a linux/arm64 stock-Go product carries R_AARCH64_TLS_TPREL64
# and cannot be dlopen()ed by musl. The OpenHarmony fork emits TLSDESC instead.
if "$CLANG_DIR/llvm-readelf" -r "$OUT" | grep -q 'R_AARCH64_TLS_TPREL64'; then
	iec_err "gh: $OUT still uses initial-exec TLS (R_AARCH64_TLS_TPREL64); build with the OpenHarmony Go toolchain (GO_OS=$GO_OS)"
fi
rm -f "${OUT%.so}.h"
iec_log "done: $OUT ($(du -h "$OUT" | cut -f1))"

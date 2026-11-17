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
# 与 gh 相同，固定到要求 go <= 1.26 的 tag（OpenHarmony 工具链基于 go1.26.5）。
GITLFS_REF="${GITLFS_REF:-v3.7.1}"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUT_DIR/libgitlfscmd.so"
WRAP="$SRC/cmd/gitlfsohos"

# 与 gh 相同：stock Go 的 c-shared 是 initial-exec TLS，鸿蒙 musl 拒绝 dlopen
# （退出码 125）。必须用 OpenHarmony Go 工具链（GOOS=openharmony，TLSDESC/GD）；
# 准备方式见 scripts/optional/fetch_go_ohos.sh。
GO_TOOLCHAIN="${GO_TOOLCHAIN:-${GO_OHOS:+$GO_OHOS/bin/go}}"
GO_TOOLCHAIN="${GO_TOOLCHAIN:-go}"
GO_OS="${GO_OS:-openharmony}"

command -v "$GO_TOOLCHAIN" >/dev/null 2>&1 || iec_err "Go toolchain not found: $GO_TOOLCHAIN"
"$GO_TOOLCHAIN" tool dist list 2>/dev/null | grep -qx "$GO_OS/arm64" \
	|| iec_err "Go toolchain $("$GO_TOOLCHAIN" version) has no $GO_OS/arm64 target. Run scripts/optional/fetch_go_ohos.sh and set GO_TOOLCHAIN=<repo>/build/go-ohos/bin/go"
iec_clone_if_missing "$SRC" "https://github.com/git-lfs/git-lfs.git" "$GITLFS_REF"

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
	GOOS="$GO_OS" GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
	"$GO_TOOLCHAIN" build -buildvcs=false -buildmode=c-shared -trimpath \
		-ldflags='-s -w' -o "$OUT" ./cmd/gitlfsohos ) \
	|| iec_err "git-lfs Go build failed"

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT" | grep ' iec_gitlfs_main$' >/dev/null \
	|| iec_err "git-lfs: entry iec_gitlfs_main is not exported"
if "$CLANG_DIR/llvm-readelf" -r "$OUT" | grep -q 'R_AARCH64_TLS_TPREL64'; then
	iec_err "git-lfs: $OUT still uses initial-exec TLS (R_AARCH64_TLS_TPREL64); build with the OpenHarmony Go toolchain (GO_OS=$GO_OS)"
fi
rm -f "${OUT%.so}.h"
iec_log "done: $OUT ($(du -h "$OUT" | cut -f1))"

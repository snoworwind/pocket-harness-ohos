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
# tag v2.100.0 的 commit（api.github.com/repos/cli/cli/commits/v2.100.0）。
GH_COMMIT="$(iec_sha_or IEC_GH_COMMIT 45437bc7eeeb3359bbfddd1742f79de7652fd3e2)"
# `gh --version` reads internal/build.Version, which defaults to "DEV" and cannot be
# recovered from build info in a c-shared build. Stamp the tag we actually built.
GH_VERSION="${GH_VERSION:-$GH_REF}"
GH_BUILD_DATE="${GH_BUILD_DATE:-$(date -u +%Y-%m-%d)}"
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
iec_clone_if_missing "$SRC" "https://github.com/cli/cli.git" "$GH_REF" "$GH_COMMIT"

# ── HarmonyOS: start IEC command objects without execve ────────────────────
# The sandbox denies execve() of ELF files in every path the app can see, and
# the runtime launchers are #IECSOv2 text files only the IEC exec service can
# start. gh's git commands all go through internal/run.PrepareCmd, so that
# package is pointed at internal/ghohos: a C child (forked in cgo) asks the exec
# service for the command, becomes its stand-in, and Go waits normally.
# See scripts/optional/gh-ohos/bridge.go and tools/iec_fork_exec.c.
GH_OHOS="$IEC_ROOT/scripts/optional/gh-ohos"
[ -d "$GH_OHOS" ] || iec_err "missing gh patches: $GH_OHOS"
mkdir -p "$SRC/internal/ghohos"
cp -f "$GH_OHOS/bridge.go" "$SRC/internal/ghohos/bridge.go"
cp -f "$IEC_ROOT/tools/iec_fork_exec.c" "$SRC/internal/ghohos/iec_fork_exec.c"
cp -f "$IEC_ROOT/exec/shim.c" "$SRC/internal/ghohos/iec_exec_shim.c"
cp -f "$IEC_ROOT/common/rpc.c" "$SRC/internal/ghohos/iec_rpc.c"
cp -f "$IEC_ROOT/common/sock_client.c" "$SRC/internal/ghohos/iec_sock_client.c"

"${HOST_PY:-python3}" - "$SRC/internal/run/run.go" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
if 'internal/ghohos' in text:
    raise SystemExit(0)

text = text.replace(
    '\t"github.com/cli/cli/v2/utils"\n',
    '\t"github.com/cli/cli/v2/internal/ghohos"\n\t"github.com/cli/cli/v2/utils"\n', 1)
text = text.replace("out, err := c.Cmd.Output()", "out, err := ghohos.Output(c.Cmd)", 1)
text = text.replace("return c.Cmd.Run()", "return ghohos.Run(c.Cmd)", 1)
text = text.replace("err := c.Cmd.Run()", "err := ghohos.Run(c.Cmd)", 1)
if 'ghohos.Output' not in text or 'ghohos.Run' not in text:
    raise SystemExit("cannot patch internal/run/run.go")
open(path, "w", encoding="utf-8").write(text)
PY

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
	CGO_CFLAGS="-I$IEC_ROOT -I$IEC_ROOT/common -DINT_PRELOAD -D_GNU_SOURCE" \
	"$GO_TOOLCHAIN" build -buildvcs=false -buildmode=c-shared -trimpath \
		-ldflags="-s -w \
			-X github.com/cli/cli/v2/internal/build.Version=$GH_VERSION \
			-X github.com/cli/cli/v2/internal/build.Date=$GH_BUILD_DATE" \
		-o "$OUT" ./cmd/ghohos ) \
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

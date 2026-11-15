#!/usr/bin/env bash
# 从上游源码为鸿蒙 arm64 编译 ripgrep，产物是可以被 IEC 装载的 .so（导出 iec_rg_main）。
#
#   bash scripts/rg/build-ripgrep.sh
#
# 输出：$RIPGREP_OUT/librg.so（默认 /var/tmp/dsh-rg/librg.so）
set -euo pipefail

NATIVE_ROOT="${NATIVE_ROOT:-/var/tmp/deepseek-harmony-native}"
RUST_TARGET="${RUST_TARGET:-aarch64-unknown-linux-ohos}"
OHOS_TARGET="${OHOS_TARGET:-aarch64-linux-ohos}"
LIB_ARCH="${LIB_ARCH:-arm64-v8a}"
RUST_HOME_ROOT="${RUST_HOME_ROOT:-$NATIVE_ROOT}"
SRC="${SRC:-/var/tmp/ripgrep-build/src}"
BUILD="${BUILD:-/var/tmp/ripgrep-build/build}"
OUT="${RIPGREP_OUT:-/var/tmp/dsh-rg}"
export CARGO_HOME="$RUST_HOME_ROOT/cargo"
export RUSTUP_HOME="$RUST_HOME_ROOT/rustup"
export PATH="$CARGO_HOME/bin:$PATH"

[ -f "$SRC/Cargo.toml" ] || { echo "缺少 ripgrep 源码：$SRC" >&2; exit 1; }

rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -a "$SRC/." "$BUILD/"
cd "$BUILD"

python3 - "$BUILD" <<'PY'
import sys
root = sys.argv[1]
cargo = root + '/Cargo.toml'
text = open(cargo, encoding='utf-8').read()
if '[lib]' not in text:
    text += '\n[lib]\nname = "rg_ohos"\npath = "crates/core/main.rs"\ncrate-type = ["cdylib"]\n'
    open(cargo, 'w', encoding='utf-8').write(text)

main = root + '/crates/core/main.rs'
text = open(main, encoding='utf-8').read()
if 'iec_rg_main' not in text:
    text += '''
/// IEC 入口：参数由进程环境提供（启动器已设置 argv），返回值作为退出码。
/// 0 = 有匹配或正常完成，1 = 无匹配/搜索失败，2 = 参数或运行错误。
#[no_mangle]
pub extern "C" fn iec_rg_main(_argc: i32, _argv: *const *const u8) -> i32 {
    use std::io::Write as _;
    let code = match run(flags::parse()) {
        Ok(code) => {
            if code == std::process::ExitCode::SUCCESS { 0 } else { 1 }
        }
        Err(err) => {
            eprintln!("{err:?}");
            2
        }
    };
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    code
}
'''
    open(main, 'w', encoding='utf-8').write(text)
PY

LINKER_VAR="CARGO_TARGET_$(echo "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')_LINKER"
export "$LINKER_VAR=$NATIVE_ROOT/compiler/bin/clang"
export RUSTFLAGS="-C link-arg=--target=$OHOS_TARGET -C link-arg=--sysroot=$NATIVE_ROOT/sdk/native/sysroot -C link-arg=-fuse-ld=lld"

echo "=== cargo build ($RUST_TARGET) ==="
cargo build --release --target "$RUST_TARGET" 2>&1 | tail -25

SO="$BUILD/target/$RUST_TARGET/release/librg_ohos.so"
[ -f "$SO" ] || { echo "没有产出 librg_ohos.so" >&2; exit 1; }
mkdir -p "$OUT"
cp "$SO" "$OUT/librg.so"
NM="$NATIVE_ROOT/sdk/native/llvm/bin/llvm-nm"
READELF="$NATIVE_ROOT/sdk/native/llvm/bin/llvm-readelf"
echo '=== 产物 ==='
"$READELF" -h "$OUT/librg.so" | grep -E 'Class|Machine|Type'
"$NM" -D --defined-only "$OUT/librg.so" | grep ' T iec_rg_main$'
echo "size: $(stat -c%s "$OUT/librg.so")"

# 放到与其他原生工具相同的位置，pack-native.sh 会一并收进 HAP。
mkdir -p "$NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH"
cp -f "$OUT/librg.so" "$NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH/librg.so"
echo "installed: $NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH/librg.so"

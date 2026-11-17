#!/usr/bin/env bash
# 从上游源码为鸿蒙 arm64 编译 ripgrep，产物是可以被 IEC 装载的 .so（导出 iec_rg_main）。
#
#   bash scripts/rg/build-ripgrep.sh
#   PCRE2=1 bash scripts/rg/build-ripgrep.sh   # 额外启用 -P/--pcre2 后端
#
# 输出：$RIPGREP_OUT/librg.so（默认 /var/tmp/dsh-rg/librg.so）
set -euo pipefail

NATIVE_ROOT="${NATIVE_ROOT:-/var/tmp/deepseek-harmony-native}"
RUST_TARGET="${RUST_TARGET:-aarch64-unknown-linux-ohos}"
OHOS_TARGET="${OHOS_TARGET:-aarch64-linux-ohos}"
LIB_ARCH="${LIB_ARCH:-arm64-v8a}"
RUST_HOME_ROOT="${RUST_HOME_ROOT:-$NATIVE_ROOT}"
# -P/--pcre2 is a build feature: without it `rg -P` answers "PCRE2 is not
# available in this build". The pcre2 crate builds its C library from the
# vendored source, so the cross compiler has to be named for the Rust target.
PCRE2="${PCRE2:-0}"
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

# ripgrep 的 CLI 解析直接读 std::env::args()。lib 被 IEC dlopen 到 shell 进程后，
# 进程 argv 属于宿主（通常是空），所以任何参数都会被忽略，只剩
# "ripgrep requires at least one pattern"。这里让解析器优先读 IEC 传进来的 argv：
# iec_rg_main 把 argc/argv 写进 IEC_CLI_ARGS，parse_low() 两处读参数的地方改走
# cli_args()。没有设置时（独立运行时）仍然回退到进程 argv。
parse = root + '/crates/core/flags/parse.rs'
text = open(parse, encoding='utf-8').read()
if 'IEC_CLI_ARGS' not in text:
    anchor = 'use std::{borrow::Cow, collections::BTreeSet, ffi::OsString};'
    if anchor not in text:
        raise SystemExit('ripgrep parse.rs: cannot find the OsString import anchor')
    text = text.replace(anchor, anchor + '''

/// IEC 传进来的命令行参数（不含 argv[0]）。lib 模式下进程 argv 是宿主的，
/// 解析器必须用这个，否则永远拿不到 pattern。
static IEC_CLI_ARGS: std::sync::Mutex<Option<Vec<OsString>>> =
    std::sync::Mutex::new(None);

pub(crate) fn set_cli_args(args: Vec<OsString>) {
    *IEC_CLI_ARGS.lock().unwrap() = Some(args);
}

fn cli_args() -> Vec<OsString> {
    if let Some(args) = IEC_CLI_ARGS.lock().unwrap().as_ref() {
        return args.clone();
    }
    std::env::args_os().skip(1).collect()
}''', 1)
    for old, new in (
        ('parser.parse(std::env::args_os().skip(1), &mut low)',
         'parser.parse(cli_args(), &mut low)'),
        ('final_args.extend(std::env::args_os().skip(1));',
         'final_args.extend(cli_args());'),
    ):
        if old not in text:
            raise SystemExit('ripgrep parse.rs: cannot find %r' % old)
        text = text.replace(old, new)
    open(parse, 'w', encoding='utf-8').write(text)

flags_mod = root + '/crates/core/flags/mod.rs'
text = open(flags_mod, encoding='utf-8').read()
if 'set_cli_args' not in text:
    old = 'parse::{parse, ParseResult},'
    if old not in text:
        raise SystemExit('ripgrep flags/mod.rs: cannot find the parse re-export')
    text = text.replace(old, 'parse::{parse, set_cli_args, ParseResult},', 1)
    open(flags_mod, 'w', encoding='utf-8').write(text)

main = root + '/crates/core/main.rs'
text = open(main, encoding='utf-8').read()
if 'iec_rg_main' not in text:
    text += '''
/// IEC 入口：参数来自启动器，而不是宿主进程的 argv（dlopen 场景下后者不可用）。
/// 0 = 有匹配或正常完成，1 = 无匹配/搜索失败，2 = 参数或运行错误。
#[no_mangle]
pub extern "C" fn iec_rg_main(argc: i32, argv: *const *const u8) -> i32 {
    use std::ffi::{CStr, OsString};
    use std::io::Write as _;
    use std::os::unix::ffi::OsStringExt as _;

    let mut args = Vec::new();
    if argc > 1 && !argv.is_null() {
        for i in 1..argc as isize {
            let p = unsafe { *argv.offset(i) };
            if p.is_null() {
                break;
            }
            let arg = unsafe { CStr::from_ptr(p as *const std::os::raw::c_char) };
            args.push(OsString::from_vec(arg.to_bytes().to_vec()));
        }
    }
    flags::set_cli_args(args);

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

CARGO_FEATURES=()
if [ "$PCRE2" = 1 ]; then
	# Use the static PCRE2 the tree already builds for git (scripts/optional/
	# build_pcre2.sh, JIT off). The bundled copy pcre2-sys would compile enables
	# sljit JIT for this target and then fails to link on musl (`__clear_cache`);
	# the tree's copy is both linkable and safe on a no-JIT device.
	PCRE2_PREFIX="${PCRE2_PREFIX:-$NATIVE_ROOT/iec/build/sysroot/usr}"
	PCRE2_PCDIR="$PCRE2_PREFIX/lib/$OHOS_TARGET/pkgconfig"
	[ -f "$PCRE2_PCDIR/libpcre2-8.pc" ] \
		|| { echo "缺少 $PCRE2_PCDIR/libpcre2-8.pc（先运行 scripts/optional/build_pcre2.sh）" >&2; exit 1; }
	export PCRE2_SYS_STATIC=0
	export PKG_CONFIG_ALLOW_CROSS=1
	export PKG_CONFIG_PATH="$PCRE2_PCDIR"
	export PKG_CONFIG_SYSROOT_DIR=""
	CARGO_FEATURES=(--features pcre2)
	echo "=== pcre2 后端：启用（-P/--pcre2，静态链 $PCRE2_PREFIX） ==="
fi

echo "=== cargo build ($RUST_TARGET) ==="
if ! cargo build --release --target "$RUST_TARGET" "${CARGO_FEATURES[@]}" \
	> "$BUILD/cargo.log" 2>&1; then
	tail -30 "$BUILD/cargo.log" >&2
	echo "cargo build failed (完整日志：$BUILD/cargo.log)" >&2
	exit 1
fi
tail -3 "$BUILD/cargo.log"

SO="$BUILD/target/$RUST_TARGET/release/librg_ohos.so"
[ -f "$SO" ] || { echo "没有产出 librg_ohos.so" >&2; exit 1; }
mkdir -p "$OUT"
cp "$SO" "$OUT/librg.so"
NM="$NATIVE_ROOT/sdk/native/llvm/bin/llvm-nm"
READELF="$NATIVE_ROOT/sdk/native/llvm/bin/llvm-readelf"
echo '=== 产物 ==='
"$READELF" -h "$OUT/librg.so" | grep -E 'Class|Machine|Type'
"$NM" -D --defined-only "$OUT/librg.so" | grep ' T iec_rg_main$'
if [ "$PCRE2" = 1 ]; then
	# The bundled PCRE2 is statically linked, so its symbols are local; grep is
	# enough to prove the backend went in instead of being compiled out. Write the
	# symbol table first: `grep -q` exits early and would SIGPIPE llvm-nm under
	# `set -o pipefail`.
	"$NM" "$OUT/librg.so" > "$OUT/librg.syms"
	if grep -q 'pcre2_compile_8' "$OUT/librg.syms"; then
		echo "pcre2: 已静态链入（rg -P 可用）"
	else
		rm -f "$OUT/librg.syms"
		echo "PCRE2=1 但没有把 pcre2 链进 librg.so" >&2
		exit 1
	fi
	rm -f "$OUT/librg.syms"
fi
# Static PCRE2 adds a lot of symbol data; the shipped object needs the code, not
# the symbol table (the same treatment the previous non-PCRE2 build had).
STRIP="${STRIP:-$NATIVE_ROOT/sdk/native/llvm/bin/llvm-strip}"
if [ -x "$STRIP" ]; then "$STRIP" --strip-unneeded "$OUT/librg.so"; fi
echo "size: $(stat -c%s "$OUT/librg.so")"

# 放到与其他原生工具相同的位置，pack-native.sh 会一并收进 HAP。
mkdir -p "$NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH"
cp -f "$OUT/librg.so" "$NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH/librg.so"
echo "installed: $NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH/librg.so"

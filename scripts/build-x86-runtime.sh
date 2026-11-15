#!/usr/bin/env bash
# Build an isolated OHOS x86_64 runtime using the existing local source cache.
set -euo pipefail
BASE=${NATIVE_BASE:-/var/tmp/deepseek-harmony-native}
ROOT=${X86_ROOT:-/var/tmp/deepseek-harmony-x86}
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
PHASE=${1:-setup}
export OHOS_SDK="$BASE/sdk" TARGET=x86_64-linux-ohos NATIVE_ARCH=x86_64 JOBS=${JOBS:-8}
export SYSROOT="$OHOS_SDK/native/sysroot"
export CLANG_DIR="$ROOT/compiler/bin" CLANG="$ROOT/compiler/bin/clang" CLANGXX="$ROOT/compiler/bin/clang++"
export OUTDIR="$ROOT/iec/platform/ohos/har/libs/x86_64"
export IEC_NODE_SRC="$ROOT/node-v24.22.1" IEC_NODE_BUILD="$ROOT/iec/build/node24"
export IEC_NODE_TARBALL="$BASE/downloads/node-v24.22.1.tar.gz"
export HOST_CC=gcc HOST_CXX=g++ HOST_AR=ar HOST_NM=nm HOST_READELF=readelf
export IEC_SOURCE_CACHE="$BASE/downloads" IEC_THIRDPARTY="$BASE/iec/thirdparty"
export IEC_DEPS_DIR="$ROOT/iec/build/sysroot"
export LIBARCHIVE_HAR_LIBS="$OUTDIR" LIBARCHIVE_BUILD="$ROOT/iec/build/libarchive"
export IEC_LIBARCHIVE_SRC="$BASE/iec/thirdparty/libarchive-3.7.7"
export TOYBOX_SRC="$BASE/iec/thirdparty/toybox"
export PATH="$ROOT/host-tools:$PATH"
mkdir -p "$ROOT/logs" "$OUTDIR"
if [ "$PHASE" = setup ]; then
  mkdir -p "$ROOT/iec" "$ROOT/compiler/bin" "$ROOT/ndk-cxx"
  mkdir -p "$ROOT/host-tools"
  # These host tools are used only by V8 code generation, never shipped in HAP.
  printf '#!/bin/sh\n/usr/bin/g++ "$@" -O0 && exit 0\nexec /usr/bin/g++ "$@" -O2\n' > "$ROOT/host-tools/g++"
  chmod +x "$ROOT/host-tools/g++"
  ln -sfn "$BASE/sdk" "$ROOT/sdk"
  ln -sfn "$BASE/official-engine" "$ROOT/official-engine"
  CRT="$BASE/sdk/native/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos"
  ln -sfn clang_rt.crtbegin.o "$CRT/crtbeginS.o"
  ln -sfn clang_rt.crtend.o "$CRT/crtendS.o"
  ln -sfn "$CRT" "$BASE/llvm22/usr/lib/clang/22/lib/x86_64-linux-ohos"
  if [ ! -f "$ROOT/iec/scripts/optional/build_node.sh" ]; then
    tar -C "$BASE/iec" --exclude=./build --exclude=./thirdparty --exclude=./.git --exclude=./platform/ohos/har/libs --exclude=./platform/ohos/har/build --exclude=./platform/ohos/har/.cxx -cf - . | tar -C "$ROOT/iec" -xf -
  fi
  cp "$PROJECT/native/iec/loader/elf_dl.cpp" "$ROOT/iec/loader/elf_dl.cpp"
  if [ ! -f "$IEC_NODE_SRC/src/node.cc" ]; then
    mkdir -p "$IEC_NODE_SRC"
    tar -C "$BASE/node-v24.22.1" --exclude=./out --exclude=./.git -cf - . | tar -C "$IEC_NODE_SRC" -xf -
  fi
  cp -a "/mnt/d/D Program Files/DevEco Studio/sdk/default/openharmony/native/llvm/lib/x86_64-linux-ohos/." "$ROOT/ndk-cxx/"
  for kind in clang clang++; do
    stdlib="-Wno-implicit-function-declaration"; [ "$kind" = clang++ ] && stdlib="-stdlib=libc++"
    optimize=""; [ "$kind" = clang++ ] && optimize="-O1"
    cat > "$ROOT/compiler/bin/$kind" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$BASE/llvm22/usr/lib/x86_64-linux-gnu"
exec "$BASE/llvm22/usr/bin/$kind-22" -resource-dir="$BASE/llvm22/usr/lib/clang/22" -nostdinc++ -isystem "$BASE/libcxx22-n1/include/c++/v1" -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -L"$ROOT/ndk-cxx" -L"$BASE/sdk/native/llvm/lib/x86_64-linux-ohos" $stdlib "\$@" $optimize
EOF
  done

  chmod +x "$ROOT/compiler/bin/clang" "$ROOT/compiler/bin/clang++"
  for tool in llvm-ar llvm-ranlib llvm-nm llvm-readelf llvm-objcopy llvm-strip ld.lld; do ln -sfn "$BASE/sdk/native/llvm/bin/$tool" "$ROOT/compiler/bin/$tool"; done
  python3 - "$ROOT" <<'PY'
import pathlib,sys
r=pathlib.Path(sys.argv[1]); p=r/'iec/scripts/optional/build_node.sh'
s=p.read_text().replace('--dest-cpu=arm64','--dest-cpu=x64').replace('guest_switch_aarch64.S','guest_switch_x86_64.S')
s=s.replace('aarch64-linux-musl/lib/libatomic.a', 'x86_64-linux-musl/lib/libatomic.a').replace('/usr/lib/gcc-cross/aarch64-linux-gnu/', '/usr/lib/gcc/x86_64-linux-gnu/')
s=s.replace('$CC_TARGET -c "$IEC_ROOT/loader/tlsdesc.S" -o "$BUILD/iec_tlsdesc.o"', ': # AArch64 TLSDESC assembly is not used on x86_64')
s=s.replace('\\"$BUILD/iec_tlsdesc.o\\" ', '')
p.write_text(s)
p=r/'iec/scripts/build_toybox.sh';p.write_text(p.read_text().replace('har/libs/arm64-v8a','har/libs/x86_64'))
p=r/'iec/scripts/build_libarchive.sh';p.write_text(p.read_text().replace('--host=aarch64-linux-musl','--host=x86_64-linux-musl'))
PY
  echo X86_SETUP_READY
elif [ "$PHASE" = node ]; then
  bash "$ROOT/iec/scripts/optional/build_node.sh" configure
  bash "$ROOT/iec/scripts/optional/build_node.sh" build
elif [ "$PHASE" = node-resume ]; then
  bash "$ROOT/iec/scripts/optional/build_node.sh" build
elif [ "$PHASE" = tools ]; then
  bash "$ROOT/iec/scripts/optional/build_zlib.sh"
  bash "$ROOT/iec/scripts/build_libarchive.sh"
  bash "$ROOT/iec/scripts/build_toybox.sh"
elif [ "$PHASE" = bash ]; then
  export IEC_ROOT="$ROOT/iec" BUILD_ROOT="$ROOT/iec/build/bash"
  mkdir -p "$BUILD_ROOT"
  cp -n "$BASE/iec/build/bash/bash-5.3.tar.gz" "$BUILD_ROOT/" || true
  bash "$PROJECT/native/build-bash.sh"
elif [ "$PHASE" = addons ]; then
  NATIVE_ROOT="$ROOT" ADDON_STAGE="$ROOT/addon-stage" ADDON_ARCH=x64 bash "$PROJECT/native/toolchain/build-addons.sh"
elif [ "$PHASE" = rg ]; then
  export CARGO_HOME="$BASE/cargo" RUSTUP_HOME="$BASE/rustup"
  "$CARGO_HOME/bin/rustup" target add x86_64-unknown-linux-ohos
  NATIVE_ROOT="$ROOT" RUST_HOME_ROOT="$BASE" RUST_TARGET=x86_64-unknown-linux-ohos OHOS_TARGET=x86_64-linux-ohos LIB_ARCH=x86_64 BUILD="$ROOT/rg-build" RIPGREP_OUT="$ROOT/rg-out" bash "$PROJECT/scripts/rg/build-ripgrep.sh"
elif [ "$PHASE" = pack ]; then
  mkdir -p "$ROOT/symbols"
  for library in "$OUTDIR"/*.so "$OUTDIR"/libarchive.so.13; do
    cp -n "$library" "$ROOT/symbols/" || true
    "$CLANG_DIR/llvm-strip" --strip-unneeded "$library"
  done
  NATIVE_ROOT="$ROOT" LIB_ARCH=x86_64 ADDON_STAGE="$ROOT/addon-stage" bash "$PROJECT/scripts/pack-native.sh"
else
  echo "Unknown phase: $PHASE" >&2; exit 1
fi

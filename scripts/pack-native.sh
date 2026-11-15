#!/usr/bin/env bash
# 把 WSL 里交叉编译出的鸿蒙原生库和官方引擎打包进应用工程。
#
# 用法（在 WSL 内）：
#   bash scripts/pack-native.sh            # 缺任何原生库就失败
#   bash scripts/pack-native.sh --partial  # 缺库时跳过并报告（用于分阶段验证）
#
# 输入：
#   $NATIVE_ROOT/iec/platform/ohos/har/libs/arm64-v8a/*.so   交叉编译产物
#   $NATIVE_ROOT/official-engine/node_modules                官方引擎依赖树
#   $ENGINE_SHIP_LIST                                        精简后的待打包文件清单
# 输出：
#   entry/libs/arm64-v8a/*.so                                随 HAP 安装的原生库
#   entry/src/main/resources/rawfile/tools/official-engine.tar.gz
#   entry/src/main/resources/rawfile/tools/runtime-manifest.json
set -euo pipefail

NATIVE_ROOT="${NATIVE_ROOT:-/var/tmp/deepseek-harmony-native}"
PROJECT="${PROJECT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB_ARCH="${LIB_ARCH:-arm64-v8a}"
case "$LIB_ARCH" in
  arm64-v8a) ELF_MACHINE=AArch64 ;;
  x86_64) ELF_MACHINE='Advanced Micro Devices X86-64' ;;
  *) echo "Unsupported library ABI: $LIB_ARCH" >&2; exit 1 ;;
esac
LIB_SRC="$NATIVE_ROOT/iec/platform/ohos/har/libs/$LIB_ARCH"
WORK="$NATIVE_ROOT/pack"
PARTIAL=0
[ "${1:-}" = "--partial" ] && PARTIAL=1

APP_VERSION="0.2.0"
ENGINE_VERSION="0.2.2-rc.1"
NODE_VERSION="24.22.1"

fail() { echo "pack-native: $*" >&2; exit 1; }
note() { echo "pack-native: $*"; }

# name|library|entry
COMMANDS='bash|libbash.so|iec_bash_main
sh|libbash.so|iec_bash_main
toybox|libtoybox.so|bsh_toybox_main
node|libnode.so|iec_node_main
npm|libnode.so|iec_npm_main
npx|libnode.so|iec_npx_main
pnpm|libnode.so|iec_pnpm_main
tar|libbsdtar.so|iec_bsdtar_main
cpio|libbsdcpio.so|iec_bsdcpio_main
unzip|libbsdunzip.so|iec_bsdunzip_main
zip|libzipcmd.so|iec_zip_main
rg|librg.so|iec_rg_main'

# libarchive.so.13 不是命令行工具，而是 archive_extract.cpp 用 dlopen 加载的共享库：
# 设备上的 unpackResource()（首次启动解官方引擎和 npm）少了它就会返回非 0。
LIBS='libbash.so libtoybox.so libbsdtar.so libbsdcpio.so libbsdunzip.so libzipcmd.so libnode.so librg.so libarchive.so.13'

mkdir -p "$PROJECT/entry/libs/$LIB_ARCH" \
         "$PROJECT/entry/src/main/resources/rawfile/tools"

missing=()
for lib in $LIBS; do
  if [ ! -f "$LIB_SRC/$lib" ]; then
    missing+=("$lib")
    [ "$PARTIAL" -eq 1 ] && continue
    fail "缺少原生库 $lib（先构建：scripts/optional/build_node.sh 等）"
  fi
  readelf -h "$LIB_SRC/$lib" | grep -F "$ELF_MACHINE" >/dev/null || fail "$lib 的 ELF 架构不匹配 $LIB_ARCH"
  cp -f "$LIB_SRC/$lib" "$PROJECT/entry/libs/$LIB_ARCH/$lib"
  note "libs/$lib $(stat -c%s "$LIB_SRC/$lib") 字节"
done

# 运行时目录名由「内容」决定，不能只写死应用版本号：否则换了引擎或原生库却没改
# 版本号时，升级后会命中旧的 .installed 标记，继续用上一次解包的旧运行时。
# 摘要 = sha256(版本号 + 引擎归档 + 每个随包 .so 的 sha256) 的前 12 位，
# 因此清单里文件名不变、只是内容变了（上游补丁版本、重编的库）也会换目录。
# 清单要等引擎归档生成后才能算，所以写在最后（见文件末尾）。
MANIFEST="$PROJECT/entry/src/main/resources/rawfile/tools/runtime-manifest.json"
SHIP_LIST="${ENGINE_SHIP_LIST:-$PROJECT/scripts/engine-ship-files.txt}"

# 引擎：精简后的 sdk 闭包 + harmony 宿主脚本。
ENGINE_TAR="$PROJECT/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
if [ -f "$SHIP_LIST" ]; then
  rm -rf "$WORK/engine"
  mkdir -p "$WORK/engine/node_modules" "$WORK/engine/harmony"
  note "解包引擎文件清单：$(wc -l < "$SHIP_LIST") 个文件"
  tar -C "$NATIVE_ROOT/official-engine/node_modules" -czf "$WORK/shipped.tar.gz" -T "$SHIP_LIST"
  tar -C "$WORK/engine/node_modules" -xzf "$WORK/shipped.tar.gz"
  cp "$PROJECT/native/terminal-host.cjs" "$WORK/engine/harmony/terminal-host.cjs"
  cp "$PROJECT/native/node-preload.mjs" "$WORK/engine/harmony/node-preload.mjs"
  # @vscode/ripgrep 只是给引擎找 rg 路径的壳；上游包会 require 平台预编译包，
  # 鸿蒙没有那个包，所以换成指向运行时启动器的同名包（本工程自写，MIT）。
  RIPGREP_PKG="$WORK/engine/node_modules/@vscode/ripgrep"
  rm -rf "$RIPGREP_PKG"
  mkdir -p "$RIPGREP_PKG/lib"
  cat > "$RIPGREP_PKG/package.json" <<'EOF'
{
  "name": "@vscode/ripgrep",
  "version": "1.18.0-harmony.1",
  "description": "HarmonyOS shim: resolves the IEC-launched ripgrep built from source.",
  "type": "module",
  "main": "./lib/index.js",
  "exports": {
    ".": {
      "default": "./lib/index.js"
    }
  },
  "license": "MIT"
}
EOF
  cat > "$RIPGREP_PKG/lib/index.js" <<'EOF'
// 上游 @vscode/ripgrep 会解析 @vscode/ripgrep-<platform>-<arch> 里的预编译 rg。
// 鸿蒙版没有预编译包：rg 由本工程从 ripgrep 源码编译成 librg.so，并由 IEC 在
// <sysroot>/bin/rg 生成启动器，这里只负责把路径告诉引擎。
import path from 'node:path';
const root = process.env.IEC_SYSROOT || '';
export const rgPath = path.join(root, 'bin', 'rg');
EOF
  note "已写入 @vscode/ripgrep 兼容包（指向 <sysroot>/bin/rg）"

  ADDON_STAGE="${ADDON_STAGE:-$NATIVE_ROOT/addon-stage}"
  if [ -d "$ADDON_STAGE/node_modules" ]; then
    cp -a "$ADDON_STAGE/node_modules/." "$WORK/engine/node_modules/"
    note "已叠加原生插件：$(find "$ADDON_STAGE/node_modules" -name '*.node' | wc -l) 个 .node"
  else
    note "未找到原生插件目录：$ADDON_STAGE（引擎启动会缺少 require-builtin / flock）"
  fi
  # 鸿蒙适配插件：随引擎分发，用 --patch 叠加在 web profile 上（不进用户 profile）。
  if [ -d "$PROJECT/plugins/harmony-compat" ]; then
    mkdir -p "$WORK/engine/node_modules/@deepseek-ai"
    rm -rf "$WORK/engine/node_modules/@deepseek-ai/dsh-harmony-compat"
    cp -a "$PROJECT/plugins/harmony-compat" "$WORK/engine/node_modules/@deepseek-ai/dsh-harmony-compat"
    mkdir -p "$WORK/engine/harmony"
    cp -f "$PROJECT/plugins/harmony-compat/cordis.patch.yml" "$WORK/engine/harmony/harmony-compat.patch.yml"
    note "鸿蒙适配插件已打包"
  fi

  printf '{"name":"deepseek-harmony-engine","private":true,"version":"%s"}\n' "$ENGINE_VERSION" \
    > "$WORK/engine/package.json"

  # pnpm：DSH 的插件管理器用 `execa("pnpm")` 装/删用户插件，设备上没有它就装不了。
  # 随引擎分发（JS 实现，由 libnode.so 的 iec_pnpm_main 入口启动）。
  PNPM_TGZ="${PNPM_TGZ:-/var/tmp/pnpm-pack/pnpm-10.34.9.tgz}"
  if [ -f "$PNPM_TGZ" ]; then
    rm -rf "$WORK/engine/node_modules/pnpm"
    mkdir -p "$WORK/engine/node_modules/pnpm"
    tar -xzf "$PNPM_TGZ" -C "$WORK/engine/node_modules/pnpm" --strip-components=1
    # pnpm's optional reflink accelerators target Windows/macOS. They are neither
    # OHOS libraries nor locally compiled artifacts; pnpm has a JS copy fallback.
    find "$WORK/engine/node_modules/pnpm" -type f -name '*.node' -delete
    note "pnpm $(grep -m1 '\"version\"' "$WORK/engine/node_modules/pnpm/package.json" | tr -d ' ",' | cut -d: -f2) 已打包"
  else
    note "警告：未找到 $PNPM_TGZ，设备上将无法安装插件"
  fi
  while IFS= read -r addon; do
    readelf -h "$addon" | grep -F "$ELF_MACHINE" >/dev/null || fail "原生插件架构不匹配 $LIB_ARCH: $addon"
  done < <(find "$WORK/engine" -type f -name '*.node')
  tar --sort=name --mtime='2026-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
      -C "$WORK/engine" -czf "$ENGINE_TAR" .
  note "official-engine.tar.gz $(stat -c%s "$ENGINE_TAR") 字节"
else
  note "跳过引擎打包：找不到 $SHIP_LIST"
fi

if [ "${#missing[@]}" -gt 0 ]; then
  note "缺库：${missing[*]}"
fi

# npm 用我们自己编的 Node 源码里的 deps/npm 打包，而不是上游仓库里的旧副本。
REBUILT_NPM="$NATIVE_ROOT/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz"
PROJECT_NPM="$PROJECT/native/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz"
if [ -f "$REBUILT_NPM" ]; then
  cp -f "$REBUILT_NPM" "$PROJECT_NPM"
  note "npm.tar.gz 取自本次 Node 源码构建（$(stat -c%s "$PROJECT_NPM") 字节）"
else
  note "警告：未找到 Node 构建产出的 npm.tar.gz，沿用仓库内副本"
fi

# 运行时清单与目录名。摘要覆盖：三个版本号 + 引擎归档全文 + npm 归档全文 +
# 每个随包 .so 全文。所以引擎、npm 或任一原生库变了都会换目录、重新解包。
RUNTIME_DIGEST=$(
  {
    printf 'app=%s\nengine=%s\nnode=%s\n' "$APP_VERSION" "$ENGINE_VERSION" "$NODE_VERSION"
    [ -f "$ENGINE_TAR" ] && sha256sum "$ENGINE_TAR"
    [ -f "$PROJECT_NPM" ] && sha256sum "$PROJECT_NPM"
    for lib in $LIBS; do
      [ -f "$PROJECT/entry/libs/$LIB_ARCH/$lib" ] && sha256sum "$PROJECT/entry/libs/$LIB_ARCH/$lib"
    done
  } | sha256sum | cut -c1-12
)
RUNTIME_VERSION="$APP_VERSION-$RUNTIME_DIGEST"
{
  printf '{\n  "version": "%s",\n  "engineVersion": "%s",\n  "nodeVersion": "%s",\n  "commands": [\n' \
    "$RUNTIME_VERSION" "$ENGINE_VERSION" "$NODE_VERSION"
  first=1
  while IFS='|' read -r name library entry; do
    [ -z "$name" ] && continue
    [ -f "$PROJECT/entry/libs/$LIB_ARCH/$library" ] || continue
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    { "name": "%s", "library": "%s", "entry": "%s" }' "$name" "$library" "$entry"
  done <<< "$COMMANDS"
  printf '\n  ]\n}\n'
} > "$MANIFEST"
note "runtime-manifest.json 已写入：version=$RUNTIME_VERSION（$(grep -c '"name"' "$MANIFEST") 个命令）"
note "完成"

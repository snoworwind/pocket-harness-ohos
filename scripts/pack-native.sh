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

ENGINE_VERSION="0.2.2-rc.1"
NODE_VERSION="24.22.1"

fail() { echo "pack-native: $*" >&2; exit 1; }
note() { echo "pack-native: $*"; }
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }
if command -v readelf >/dev/null 2>&1; then
  READELF=readelf
elif command -v llvm-readelf >/dev/null 2>&1; then
  READELF=llvm-readelf
elif command -v xcrun >/dev/null 2>&1 && xcrun --find llvm-readelf >/dev/null 2>&1; then
  READELF="xcrun llvm-readelf"
else
  READELF=""
fi

# name|library|entry|arity|elf-stub
# 最后一列非空表示该命令同时需要 ELF 启动桩：bin/<name> 是真正的 ELF（Go 的
# os/exec 直接 execve 才能执行），启动器写到 bin/<name>.iecso。git-lfs 与 gh 都用
# Go 的 os/exec 调 `git`，没有桩时会报 exec format error。
COMMANDS='bash|libbash.so|iec_bash_main|3
sh|libbash.so|iec_bash_main|3
toybox|libtoybox.so|bsh_toybox_main
node|libnode.so|iec_node_main
npm|libnode.so|iec_npm_main
npx|libnode.so|iec_npx_main
pnpm|libnode.so|iec_pnpm_main
python|libpython.so|Py_BytesMain
python3|libpython.so|Py_BytesMain
pip|libpython.so|iec_pip_main
tar|libbsdtar.so|iec_bsdtar_main
cpio|libbsdcpio.so|iec_bsdcpio_main
unzip|libbsdunzip.so|iec_bsdunzip_main
zip|libzipcmd.so|iec_zip_main
rg|librg.so|iec_rg_main
git|libgit.so|iec_git_main
git-remote-http|libgit-remote-http.so|iec_git_remote_http_main
git-remote-https|libgit-remote-http.so|iec_git_remote_http_main
git-lfs|libgitlfscmd.so|iec_gitlfs_main
curl|libcurlcmd.so|iec_curl_main
jq|libjqcmd.so|iec_jq_main
bc|libbccmd.so|iec_bc_main
nc|libnc.so|iec_nc_main
hexdump|libhexdump.so|iec_hexdump_main
diff|libdiff.so|iec_diff_main
ssh|libdropbear.so|iec_dropbear_main
scp|libdropbear.so|iec_dropbear_main
ssh-keygen|libdropbear.so|iec_dropbear_main
dbclient|libdropbear.so|iec_dropbear_main
dropbear|libdropbear.so|iec_dropbear_main
dropbearkey|libdropbear.so|iec_dropbear_main
dropbearconvert|libdropbear.so|iec_dropbear_main
sftp|libsftpcmd.so|iec_sftp_main
less|liblesscmd.so|iec_less_main
more|liblesscmd.so|iec_less_main
vi|libvimcmd.so|iec_vim_main
vim|libvimcmd.so|iec_vim_main
gh|libghcmd.so|iec_gh_main
openssl|libopensslcmd.so|iec_openssl_main
tree|libtreecmd.so|iec_tree_main
sqlite3|libsqlite3cmd.so|iec_sqlite3_main
rsync|librsynccmd.so|iec_rsync_main
xz|libxzcmd.so|iec_xz_main
unxz|libxzcmd.so|iec_xz_main
xzcat|libxzcmd.so|iec_xz_main
lzma|libxzcmd.so|iec_xz_main
unlzma|libxzcmd.so|iec_xz_main
lzcat|libxzcmd.so|iec_xz_main
zstd|libzstdcmd.so|iec_zstd_main
unzstd|libzstdcmd.so|iec_zstd_main
zstdcat|libzstdcmd.so|iec_zstd_main'

# libarchive.so.13 不是命令行工具，而是 archive_extract.cpp 用 dlopen 加载的共享库：
# 设备上的 unpackResource()（首次启动解官方引擎和 npm）少了它就会返回非 0。
# libgit-remote-http.so 同时承载 git-remote-http 与 git-remote-https 两个启动器。
LIBS='libbash.so libtoybox.so libbsdtar.so libbsdcpio.so libbsdunzip.so libzipcmd.so libnode.so libpython.so librg.so libarchive.so.13 libgit.so libgit-remote-http.so libgitlfscmd.so libcurlcmd.so libjqcmd.so libbccmd.so libnc.so libhexdump.so libdiff.so libdropbear.so libsftpcmd.so liblesscmd.so libvimcmd.so libghcmd.so libopensslcmd.so libtreecmd.so libsqlite3cmd.so librsynccmd.so libxzcmd.so libzstdcmd.so'

mkdir -p "$PROJECT/entry/libs/$LIB_ARCH" \
         "$PROJECT/entry/src/main/resources/rawfile/tools"

missing=()
for lib in $LIBS; do
  if [ ! -f "$LIB_SRC/$lib" ]; then
    missing+=("$lib")
    [ "$PARTIAL" -eq 1 ] && continue
    fail "缺少原生库 $lib（先构建：scripts/optional/build_node.sh 等）"
  fi
  if [ -n "$READELF" ]; then
    "$READELF" -h "$LIB_SRC/$lib" | grep -F "$ELF_MACHINE" >/dev/null || fail "$lib 的 ELF 架构不匹配 $LIB_ARCH"
  fi
  cp -f "$LIB_SRC/$lib" "$PROJECT/entry/libs/$LIB_ARCH/$lib"
  note "libs/$lib $(file_size "$LIB_SRC/$lib") 字节"
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
ENGINE_SUMS="$PROJECT/entry/src/main/resources/rawfile/tools/official-engine.sha256"
[ -d "$NATIVE_ROOT/official-engine/node_modules" ] \
  || fail "缺少 $NATIVE_ROOT/official-engine/node_modules（先在本机 npm install 官方引擎，再打包）"
[ -f "$SHIP_LIST" ] \
  || fail "缺少引擎文件清单 $SHIP_LIST（不能跳过 official-engine.tar.gz）"
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
  # 壳层插件（harmony-compat / 原生终端）随 HAP rawfile 分发，应用启动时同步进
  # profile，不再打进引擎归档：否则改一行插件文案就会改变归档字节、进而换运行时
  # 版本、触发所有设备重新解包 450 MB。这里顺手清掉旧暂存树里遗留的副本，保证
  # 重新打包后的归档里没有它。
  rm -rf "$WORK/engine/node_modules/@deepseek-ai/dsh-harmony-compat"
  rm -f "$WORK/engine/harmony/harmony-compat.patch.yml"
  note "壳层插件改由 rawfile 分发，引擎归档不再包含 harmony-compat"
  # 图片附件：随包引擎不含 sharp 原生模块，ArkWeb 侧也没有 WASM 兜底，给
  # attachment-local 追加纯 JS 头解析 + 原字节透传（issue #1 方案 B）。
  # 补丁在解包后的暂存树上原地追加，不改上游 node_modules，也不改 ship 清单。
  ATTACHMENT_INDEX="$WORK/engine/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js"
  [ -f "$ATTACHMENT_INDEX" ] || fail "引擎里找不到 @deepseek-ai/dsh-attachment-local/lib/index.js"
  node "$PROJECT/scripts/engine-patch/attachment-pure-js.mjs" "$ATTACHMENT_INDEX" \
    || fail "附件图片纯 JS 降级补丁应用失败"
  note "附件图片降级补丁已应用"

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
    if [ -n "$READELF" ]; then
      "$READELF" -h "$addon" | grep -F "$ELF_MACHINE" >/dev/null || fail "原生插件架构不匹配 $LIB_ARCH: $addon"
    fi
  done < <(find "$WORK/engine" -type f -name '*.node')
  # 完整性清单：上游依赖树可能没有 lockfile；有则一并归档，并总是生成逐文件
  # SHA-256 清单（ENGINE-MANIFEST.sha256），便于 runtime-manifest/审计抽查。
  if [ -f "$NATIVE_ROOT/official-engine/package-lock.json" ]; then
    cp -f "$NATIVE_ROOT/official-engine/package-lock.json" "$WORK/engine/package-lock.json"
    note "已归档 package-lock.json"
  else
    note "警告：$NATIVE_ROOT/official-engine 缺少 package-lock.json，仅依赖逐文件 SHA-256 清单"
  fi
  ( cd "$WORK/engine" && \
    find . -type f ! -name ENGINE-MANIFEST.sha256 -print0 | sort -z | xargs -0 -r sha256sum \
  ) > "$WORK/engine/ENGINE-MANIFEST.sha256" \
    || fail "生成 ENGINE-MANIFEST.sha256 失败"
  note "引擎完整性清单：$(wc -l < "$WORK/engine/ENGINE-MANIFEST.sha256") 个文件"
  tar --sort=name --mtime='2026-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
      -C "$WORK/engine" -czf "$ENGINE_TAR" .
  note "official-engine.tar.gz $(file_size "$ENGINE_TAR") 字节"
  ( cd "$(dirname "$ENGINE_SUMS")" && sha256sum official-engine.tar.gz ) > "$ENGINE_SUMS" \
    || fail "生成 official-engine.sha256 失败"
  ( cd "$(dirname "$ENGINE_SUMS")" && sha256sum -c official-engine.sha256 >/dev/null ) \
    || fail "official-engine.sha256 自校验失败"
  note "official-engine.sha256 已写入并自校验通过"
fi

if [ "${#missing[@]}" -gt 0 ]; then
  note "缺库：${missing[*]}"
fi

# CPython 标准库（含 pip/setuptools/wheel）与 Vim 运行时由各自构建脚本产出。
PYTHON_STDLIB_SRC="$PROJECT/native/iec/platform/ohos/har/src/main/resources/rawfile/tools/python-stdlib.tar"
if [ -f "$PYTHON_STDLIB_SRC" ]; then
  cp -f "$PYTHON_STDLIB_SRC" "$PROJECT/entry/src/main/resources/rawfile/tools/python-stdlib.tar"
  note "python-stdlib.tar $(file_size "$PROJECT/entry/src/main/resources/rawfile/tools/python-stdlib.tar") 字节"
else
  fail "缺少 $PYTHON_STDLIB_SRC（先运行 native/iec/scripts/optional/build_python.sh）"
fi
VIM_RUNTIME_SRC="$PROJECT/native/iec/platform/ohos/har/src/main/resources/rawfile/tools/vim-runtime.tar.gz"
if [ -f "$VIM_RUNTIME_SRC" ]; then
  cp -f "$VIM_RUNTIME_SRC" "$PROJECT/entry/src/main/resources/rawfile/tools/vim-runtime.tar.gz"
  note "vim-runtime.tar.gz 已复制"
else
  fail "缺少 $VIM_RUNTIME_SRC（先运行 native/iec/scripts/optional/build_vim.sh）"
fi

# npm 用我们自己编的 Node 源码里的 deps/npm 打包，而不是上游仓库里的旧副本。
# npm.tar.gz 已改为构建产物（不再跟踪）：缺少本次构建产物时直接失败，绝不回退到
# 仓库里的旧归档；--partial 只影响原生库缺失，不改变这条规则。
REBUILT_NPM="$NATIVE_ROOT/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz"
PROJECT_NPM="$PROJECT/entry/src/main/resources/rawfile/tools/npm.tar.gz"
[ -f "$REBUILT_NPM" ] \
  || fail "缺少本次 Node 构建产出的 npm.tar.gz：$REBUILT_NPM（先跑 scripts/optional/build_node.sh；不要复用旧副本）"
cp -f "$REBUILT_NPM" "$PROJECT_NPM"
note "npm.tar.gz 取自本次 Node 源码构建（$(file_size "$PROJECT_NPM") 字节）"

# 运行时清单。version 不在这里手算：交给 scripts/runtime-manifest.mjs 按四个
# 运行时归档（engine/npm/python-stdlib/vim）的字节 + commands 列表计算，并把
# 哈希只在此时临时计算，不写进清单，没有任何需要人跟的数据。entry/libs 的 .so
# 不计入：它们直接从 HAP 加载、启动器每次启动重写，原生库变化不需要换运行时目录。
# 归档变了版本一定变，不会出现「产物变了但清单没变」。
[ -s "$ENGINE_TAR" ] || fail "缺少 $ENGINE_TAR（引擎归档未生成，拒绝继续）"
[ -s "$ENGINE_SUMS" ] || fail "缺少 $ENGINE_SUMS（引擎完整性清单未生成，拒绝继续）"
[ -s "$PROJECT_NPM" ] || fail "缺少 $PROJECT_NPM（npm.tar.gz 未生成，拒绝继续）"
{
  printf '{\n  "version": "",\n  "engineVersion": "%s",\n  "nodeVersion": "%s",\n  "commands": [\n' \
    "$ENGINE_VERSION" "$NODE_VERSION"
  first=1
  while IFS='|' read -r name library entry arity stub; do
    [ -z "$name" ] && continue
    [ -f "$PROJECT/entry/libs/$LIB_ARCH/$library" ] || continue
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    if [ -n "$arity" ] && [ -n "$stub" ]; then
      printf '    { "name": "%s", "library": "%s", "entry": "%s", "arity": %s, "elfStub": true }' "$name" "$library" "$entry" "$arity"
    elif [ -n "$arity" ]; then
      printf '    { "name": "%s", "library": "%s", "entry": "%s", "arity": %s }' "$name" "$library" "$entry" "$arity"
    elif [ -n "$stub" ]; then
      printf '    { "name": "%s", "library": "%s", "entry": "%s", "elfStub": true }' "$name" "$library" "$entry"
    else
      printf '    { "name": "%s", "library": "%s", "entry": "%s" }' "$name" "$library" "$entry"
    fi
  done <<< "$COMMANDS"
  printf '\n  ]\n}\n'
} > "$MANIFEST"
if ! command -v node >/dev/null 2>&1; then
  fail "找不到 node，无法计算 runtime-manifest.version；请先安装 Node 18+ 后重跑，或直接运行 node scripts/runtime-manifest.mjs sync"
fi
node "$PROJECT/scripts/runtime-manifest.mjs" sync
RUNTIME_VERSION=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' "$MANIFEST" | head -1)
[ -n "$RUNTIME_VERSION" ] || fail "runtime-manifest.version 回读失败"
note "runtime-manifest.json 已写入：version=$RUNTIME_VERSION（$(grep -c '"name"' "$MANIFEST") 个命令）"
note "完成"

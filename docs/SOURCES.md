# 随包组件的来源

规则：**HAP 里的二进制要么来自华为官方 SDK，要么来自 DeepSeek 官方发布物，要么在本机从源码编译。** 没有第三种来源，也没有把第三方预编译二进制塞进包里。

核对方式：`bash scripts/audit-sources.sh`。它解包 HAP，列出全部二进制，和预期集合比对，检查引擎归档里的原生插件与 `official-engine.sha256`，并把 `npm.tar.gz` 与本次 Node 构建的产物做逐字节比较；同时检查随包 ELF 的 RELRO / BIND_NOW / NX / stack canary 标志。`bash scripts/audit-binaries.sh` 独立审计引擎/npm 归档与 HAP 内的 ELF。

## 来源固定与校验（M-03）

统一实现位于 `native/iec/scripts/lib/common.sh`：

- `iec_fetch_verified <url> <dest> <sha256|UNPINNED> [label]`：`curl -fL` 下载到 `.part`，按 SHA-256 校验，不匹配立即退出；已有文件先校验再决定是否重下。
- `iec_clone_if_missing <dir> <url> [ref] [commit]`：git 依赖按 commit checkout/fetch 并核对 `HEAD`；已有 checkout 的 `HEAD` 与固定 commit 不一致时直接失败。
- 所有校验值都可用同名环境变量覆盖（如 `IEC_LIBARCHIVE_SHA256`、`IEC_GIT_COMMIT`），默认必须校验。
- 仍保留 `UNPINNED` 机制供未来新增依赖使用：普通构建打印警告后继续；`AUDIT_STRICT=1`（或 `CI`/`GITHUB_ACTIONS` 非空）时直接失败。当前仓库内所有构建脚本都已固定校验值或 commit，不再有 `UNPINNED` 条目。

### A. 上游提供可核对的 SHA-256 或 commit

| 组件 | 版本 | 固定值 | 依据 URL |
| --- | --- | --- | --- |
| Node.js 源码包 | v24.22.1（与随包 `libnode.so` 一致） | `001773d9bd53fbd27a25efd42aa6a9693ebfe500998ca9bec635e9b6ee79bc91` | <https://nodejs.org/dist/v24.22.1/SHASUMS256.txt> |
| CPython 源码包 | 3.12.14 | `5c8462af5790baf43a321a1559dbe0db06d1be4300fb85fb53c40060668e548a` | <https://www.python.org/downloads/release/python-31214/> |
| libarchive 源码包 | 3.7.7 | `879acd83c3399c7caaee73fe5f7418e06087ab2aaf40af3e99b9e29beb29faee` | <https://libarchive.org/downloads/libarchive-3.7.7.tar.xz.sums.txt> |
| zstd 源码包 | 1.5.7 | `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3` | <https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz.sha256> |
| git | 2.56.0 | commit `a018953688f1b10bddf91bff8747068f5f4746a4` | <https://api.github.com/repos/git/git/commits/v2.56.0> |
| PCRE2 | 10.49 | commit `6f9d7c1373262c541324a16a358785b33ef116cf` | <https://api.github.com/repos/PCRE2Project/pcre2/commits/pcre2-10.49> |
| Dropbear | main（审查基线） | commit `99baf1828c13e88de048e641d03694bfe8923251` | <https://api.github.com/repos/mkj/dropbear/git/ref/heads/main> |
| toybox | main（审查基线） | commit `6a0c0ef5eeb2c43e4feef9781398c1718b8bddcb` | <https://api.github.com/repos/landley/toybox/commits/master> |
| GitHub CLI | v2.100.0 | commit `45437bc7eeeb3359bbfddd1742f79de7652fd3e2` | <https://api.github.com/repos/cli/cli/commits/v2.100.0> |
| Git LFS | v3.7.1 | commit `b84b33847fe6458f36ef521534dc0eac953cb379` | <https://api.github.com/repos/git-lfs/git-lfs/git/tags/v3.7.1> |
| ncurses（Python 依赖） | master（审查基线） | commit `87c2c84cbd2332d6d94b12a1dcaf12ad1a51a938` | <https://api.github.com/repos/mirror/ncurses/git/ref/heads/master> |
| libffi（Python 依赖） | master（审查基线） | commit `de7afe7aa9e8ab7ac36429428a7222caae1e7988` | <https://api.github.com/repos/libffi/libffi/git/ref/heads/master> |
| mksh | OpenHarmony 镜像 master | commit `8947a4decf46c535f439d866bcf7d2f74d71f519` | <https://gitcode.com/openharmony/third_party_mksh>（`git ls-remote`，2026-11 基线） |

### B. 上游无 SHA-256 文件：按官方下载地址计算的可复现基线

这些项目只发布 PGP 签名或 SHA-512/SHA3 校验，没有机器可读的 SHA-256。下表的值由脚本**实际使用的官方 URL** 下载后计算，已写入对应构建脚本；上游发布物变化时校验会立刻失败，需要人工复核。GitHub tag/commit 归档（codeload）不是官方 checksum，只保证与固定 commit 的字节一致。

| 组件 | 版本/归档 | 固定 SHA-256 | 来源 |
| --- | --- | --- | --- |
| zlib | 1.3.1 | `9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23` | <https://github.com/madler/zlib/releases/tag/v1.3.1> |
| bzip2 | 1.0.8 | `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269` | <https://sourceware.org/pub/bzip2/> |
| XZ Utils | 5.8.1 | `507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543` | <https://tukaani.org/xz/> |
| curl | 8.22.0 | `d54dd598bf05927a726deb38df31c6a255ba83ff1de57c5d1464dac3ed8f44a1` | <https://curl.se/download/curl-8.22.0.tar.gz> |
| SQLite | 3.50.4（autoconf） | `a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18` | <https://sqlite.org/2025/sqlite-autoconf-3500400.tar.gz> |
| jq | 1.7.1（tag 归档） | `fc75b1824aba7a954ef0886371d951c3bf4b6e0a921d1aefc553f309702d6ed1` | <https://github.com/jqlang/jq/releases/tag/jq-1.7.1> |
| oniguruma | 6.9.9（tag 归档） | `001aa1202e78448f4c0bf1a48c76e556876b36f16d92ce3207eccfd61d99f2a0` | <https://github.com/kkos/oniguruma/releases/tag/v6.9.9> |
| less | 668 | `2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8` | <https://www.greenwoodsoftware.com/less/> |
| Vim 源码包 | 9.1.1000（commit 归档） | `9eac83abda00a15712e67ebb2073a0b74bd37a431ed93ebba510c1b6896c0793` | <https://github.com/vim/vim/tree/ebea31e454b9a1731cde845226f2c28ca5c097b1> |
| rsync | 3.4.1 | `2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52` | <https://download.samba.org/pub/rsync/src/> |
| bc | 1.07.1 | `62adfca89b0a1c0164c2cdca59ca210c1d44c3ffc46daf9931cf4942664cb02a` | <https://ftp.gnu.org/gnu/bc/> |
| tree 源码包 | 2.2.1（commit 归档） | `6daa27cd1f01f1b2d806f1c71b3cb78f896987e197d4215ea834f09373ff5fdf` | <https://github.com/Old-Man-Programmer/tree/tree/d501b58ff9cbfd64272c8cbcad0bda36a3fada06> |
| OpenSSH sftp | 9.9p2 | `91aadb603e08cc285eddf965e1199d02585fa94d994d6cae5b41e1721e215673` | <https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/> |
| readline | 8.2 | `3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35` | <https://ftp.gnu.org/gnu/readline/> |
| OpenSSL | 3.0.22（commit 归档） | commit `a279090b9cd6b682a5a178410765a63e619fa2d9` / `c0c35e149509a7aa9ea5671227da699d0d1636f088e00cb2ff31aea6feda391f` | <https://github.com/openssl/openssl/tree/a279090b9cd6b682a5a178410765a63e619fa2d9> |

引擎与 npm 归档的完整性：

- `pack-native.sh` 打包 `official-engine.tar.gz` 时生成归档内 `ENGINE-MANIFEST.sha256`（逐文件 SHA-256；若 `official-engine/package-lock.json` 存在也一并归档），并在 `rawfile/tools/official-engine.sha256` 写入归档自身的 SHA-256。
- `scripts/runtime-manifest.mjs` 在 `sync`/`check` 前核对 `official-engine.sha256` 与归档字节一致，不一致直接失败。
- `npm.tar.gz` 改为构建产物：`.gitignore` 已忽略 `native/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz`；`pack-native.sh` 只接受本次 Node 构建产出的归档，缺失即失败，不再回退到旧副本（`--partial` 只对缺失的原生库生效）。
- 旧的跟踪项已在本次改动中从索引移除（`git rm --cached native/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz`，工作区文件保留并被忽略）；提交时需带上这条删除记录。

审计脚本的路径均可配置：`HAP`、`WORKDIR`、`NATIVE_ROOT`、`READELF`、`T`、`N`；不再写死 `/mnt/d` 或 `/var/tmp`。


## 二进制

| 包里文件 | 上游源码 | 本机怎么来的 | 许可 |
| --- | --- | --- | --- |
| `libnode.so` | Node.js v24.22.1 源代码包（nodejs.org，SHA-256 校验） | `native/toolchain/build-node24.sh` → `build_node.sh`，OHOS sysroot + LLVM 22 驱动编译，`llvm-strip --strip-unneeded` | MIT |
| `libbash.so` | GNU Bash 5.3（ftp.gnu.org） | `native/build-bash.sh`，`--host=aarch64-linux-ohos` | GPL-3.0 |
| `libtoybox.so` | toybox 0.8.14 | `native/iec/scripts/build_toybox.sh` | BSD |
| `libbsdtar.so`、`libbsdcpio.so`、`libbsdunzip.so`、`libzipcmd.so` | libarchive 3.7.7 | `native/iec/scripts/build_libarchive.sh`；zlib/bzip2/xz/zstd 四个编解码器静态链入（`build_bzip2.sh`、`build_xz.sh`、`build_zstd.sh` 提供 `libbz2.a`/`liblzma.a`/`libzstd.a`），所以 `tar -j/-J/--zstd` 不再依赖不存在的 `bzip2` 命令；`unzip -v` 由 `unzip_entry.c` 补上，`zip -v` 由 `zip_entry.c` 补上 | BSD-2-Clause |
| `libarchive.so.13` | libarchive 3.7.7 | 同上脚本的 `--enable-shared` 产物（链 `fs/shim.c`，只依赖 `libc.so`）；`scripts/pack-native.sh` 复制进 `entry/libs`，供 `archive_extract.cpp` 在运行期 `dlopen` 解包引擎与 npm | BSD-2-Clause |
| `libiec_server.so`、`libncploader.so` | `native/iec` 源码（Bettersh/Guncat，随仓库） | hvigor 的 `externalNativeOptions` 用 DevEco NDK 现场编译 | 见 `native/BETTERSH-LICENSE`、`native/GUNCAT-LICENSE` |
| `libc++_shared.so` | DevEco Studio SDK（华为官方） | hvigor 从 SDK 拷贝 | LLVM Apache-2.0-with-LLVM-exception |
| `require_builtin.node` | `github.com/deepseek-ai/dsh-node-addon-require-builtin`（DeepSeek 官方，master 分支源码） | `native/toolchain/build-addons.sh`，NAPI_VERSION=9 | MIT |
| `system.node` | `@deepseek-ai/node-addon-system` 包内 `src/flock.c`（DeepSeek 官方） | 同上脚本编译 | BSD-3-Clause |
| `pty.node` | node-pty 1.2.0-beta.15 源码里的 `src/unix/pty.cc`（微软，MIT） | `native/toolchain/build-addons.sh` 用 OHOS 工具链 + node-addon-api 编译成 NAPI 插件，加载路径为 `node-pty/build/Release/pty.node` | MIT |
| `librg.so` | ripgrep 14.1.1 源码（crates.io） | `scripts/rg/build-ripgrep.sh`，cargo 目标 `aarch64-unknown-linux-ohos`，编译成导出 `iec_rg_main` 的 cdylib；入口用启动器传入的 `_argc/_argv` 重建参数（dlopen 后 `std::env::args()` 拿到的是宿主 argv，会导致 `rg` 永远“没有 pattern”），`llvm-strip --strip-unneeded` 后 4.9 MB | Unlicense OR MIT |
| `libgit.so` | Git 2.56.0 源码（github.com/git/git） | `native/iec/scripts/optional/build_git.sh`：`-fPIC` 编译 git.o + builtin + libgit.a，`llvm-objcopy --redefine-sym main=iec_git_main`，再链 IEC shim 与静态 zlib/PCRE2/OpenSSL/libcurl 成共享库；只导出 `iec_git_main` | GPL-2.0 |
| `libgit-remote-http.so` | Git 2.56.0 的 `remote-curl.c` + `http.c` + `http-walker.c` | 同上脚本，入口 `iec_git_remote_http_main`；同时供 `git-remote-http` 与 `git-remote-https` 两个启动器使用，静态链 libcurl/OpenSSL/zlib | GPL-2.0；静态依赖见 `LICENSES/curl.txt`、`LICENSES/Apache-2.0-OpenSSL.txt`、`LICENSES/zlib.txt` |
| `libpython.so` | CPython 3.12.14 | `native/iec/scripts/optional/build_python.sh`，静态扩展转为共享对象，入口 `Py_BytesMain` / `iec_pip_main`；`_bz2` 来自本机编译的 `libbz2.a`，标准库保留 `ensurepip` 并补 `_bundled` pip wheel（`python3 -m venv` 可用，且清掉 macOS 的 `._*` 文件） | PSF-2.0 |
| `libcurlcmd.so` | curl 8.22.0 命令行 | `native/iec/scripts/optional/build_curlcmd.sh`，复用 libcurl 静态库 | curl |
| `libopensslcmd.so` | OpenSSL 3.0.22 CLI | `native/iec/scripts/optional/build_opensslcmd.sh`；`build_openssl.sh` 把 `--openssldir` 固定为 `/etc/ssl`（曾经编进构建机的 `/Users/...`，导致 `openssl req`/`ca` 找不到配置），运行时的真实配置由 `rawfile/harmony/openssl.cnf` 落到 `<sysroot>/certs/openssl.cnf`，`OPENSSL_CONF` 指向它 | Apache-2.0 |
| `libjqcmd.so` | jq 1.7.1 + oniguruma 6.9.9 | `native/iec/scripts/optional/build_jq.sh` | MIT / BSD-2-Clause |
| `libbccmd.so` | GNU bc 1.07.1 | `native/iec/scripts/optional/build_bc.sh` | GPL-3.0 |
| `libnc.so`、`libhexdump.so`、`libdiff.so` | 本仓库 `native/iec/scripts/optional/cmd_*.c` | `native/iec/scripts/build_extra_commands.sh` | MIT |
| `libdropbear.so` | Dropbear SSH（含 bundled libtomcrypt/libtommath） | `native/iec/scripts/optional/build_dropbear.sh`，入口 `iec_dropbear_main`，按 argv[0] 提供 ssh/scp/ssh-keygen 等 | MIT / public domain |
| `libsftpcmd.so` | OpenSSH 9.9p2 sftp | `native/iec/scripts/optional/build_sftp.sh`，入口 `iec_sftp_main` | BSD-style |
| `liblesscmd.so` | less 668 | `native/iec/scripts/optional/build_less.sh`，静态链 ncursesw | Less License |
| `libvimcmd.so` | Vim 9.1.1000（small） | `native/iec/scripts/optional/build_vim.sh`，入口 `iec_vim_main`，运行时单独打包 | Vim License |
| `libtreecmd.so` | tree 2.2.1 | `native/iec/scripts/optional/build_tree.sh` | GPL-2.0 |
| `libsqlite3cmd.so` | SQLite 3.50.4 | `native/iec/scripts/optional/build_sqlite3.sh` | Public domain |
| `librsynccmd.so` | rsync 3.4.1（bundled popt） | `native/iec/scripts/optional/build_rsync.sh` | GPL-3.0 / MIT |
| `libxzcmd.so` | XZ Utils 5.8.1 | `native/iec/scripts/optional/build_xz.sh` | Public domain / LGPL-2.1+ |
| `libzstdcmd.so` | zstd 1.5.7 | `native/iec/scripts/optional/build_zstd.sh` | BSD-3-Clause |
| `libghcmd.so` | GitHub CLI 源码 | `native/iec/scripts/optional/build_gh.sh`，Go c-shared，入口 `iec_gh_main`；必须用 OpenHarmony Go 工具链（`GOOS=openharmony`，见 `fetch_go_ohos.sh`）产出 TLSDESC，stock Go 的 initial-exec TLS 会被鸿蒙 musl 拒绝 dlopen | MIT / Go BSD-3-Clause |
| `libgitlfscmd.so` | Git LFS 源码 | `native/iec/scripts/optional/build_gitlfs.sh`，Go c-shared，入口 `iec_gitlfs_main`；同样要求 OpenHarmony Go 工具链（TLSDESC） | MIT / Go BSD-3-Clause |

> 两个 git 库静态链接了 zlib 1.3.1、PCRE2 10.49、OpenSSL 3.0.22、libcurl 8.22.0；它们不单独随包分发，许可证原文分别在 `LICENSES/zlib.txt`、`LICENSES/pcre2.txt`、`LICENSES/Apache-2.0-OpenSSL.txt`、`LICENSES/curl.txt`。

## 数据归档

| 包里文件 | 来源 | 说明 |
| --- | --- | --- |
| `official-engine.tar.gz` | `npm install @deepseek-ai/dsh@0.2.2-rc.1`（DeepSeek 官方发布物） | 只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与外部平台 `prebuilds/`，其余保留（闭包 572 个包 / 25,606 个文件 / 43.8 MB gzip）；再叠加上面三个本机编译的插件。用于 sdk 与 web 两个 profile（111 / 291 个插件），见 `scripts/check-engine-dump.sh`、`scripts/check-engine-web.sh`、`scripts/engine-prune/finalize-ship-list.sh` |
| `npm.tar.gz` | Node.js v24.22.1 源码树里的 `deps/npm`（npm 11.19.1） | `build_node.sh` 打包；**构建产物，不进入版本库**。`pack-native.sh` 缺少本次构建产物时直接失败，不再复用仓库旧副本；审计脚本校验与构建产物一致 |
| `node_modules/@vscode/ripgrep` | 本工程自写的兼容包（MIT） | 上游包只做「找到 rg 路径」这一件事，且会 require 平台预编译包；这里换成把 `rgPath` 指向 `<sysroot>/bin/rg` 的 8 行模块 |
| `assets/cacert.pem` | Mozilla CA 根证书集 | 纯数据，编译进 `libiec_server.so` |
| `node_modules/@deepseek-ai/dsh-harmony-compat` | 本仓库 `plugins/harmony-compat`（MIT） | 内容与 `entry/src/main/resources/rawfile/tools/harmony-compat/` 一致：随 HAP rawfile 分发、启动时优先同步进 profile（引擎归档里的副本只当兜底），避免归档未重打时装进旧插件；`scripts/pack-native.sh` 仍会把同一份覆盖进引擎归档 |
| `node_modules/@local/dsh-harmony-terminal` | 本仓库 `plugins/dsh-harmony-terminal`（MIT） | 原生终端 tab 插件，随 HAP rawfile 分发、启动时同步进 profile |
| `entry/src/main/resources/rawfile/harmony/extra-ca.pem` | 用户自行提供，**不随仓库分发** | 可选附加 CA，用于会拦截 HTTPS 的开发环境；公开构建保持缺省 |

## 构建工具（不随包分发）

这些只在本机用来编译，不进入 HAP：

- OpenHarmony clang 15 工具链与 sysroot（华为官方，`repo.huaweicloud.com` 与 DevEco SDK）；
- LLVM 22 驱动、libc++ 22 头文件（Ubuntu 26.04 的 `clang-22`、`libc++-22-dev` 等包）；
- 宿主机 GCC 15、CMake、Ninja、Python、Node（只在 WSL 里跑脚本）。

关于 libc++：编译 `libnode.so` 与三个 `.node` 插件用的是 **libc++ 22 的头文件，并把 `_LIBCPP_ABI_NAMESPACE` 设为 `__n1`**（V8 需要 `<ranges>`；随包的 `libc++_shared.so` 只导出 `std::__n1` 符号）。头文件与运行库的命名空间必须一致：用默认 `__1` 头文件编出来的产物，在真机上 `dlopen` 会报 `_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`。没有链接任何非官方 libc++ 库文件。

## 已知未纳入的组件

- 其余第三方原生库没有随包；后续新增组件同样必须从源码编译，并同步更新本表与 `scripts/audit-sources.sh`。

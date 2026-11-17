# 验证说明

记录截至 2026-11-17 的验证范围。凡是没在真机上跑过的条目都明确标为「未验收」，不写成已通过。测试设备为一台 HarmonyOS 6.1（API 26）手机与 x86_64 模拟器。

## 已确认

| 项目 | 操作 | 结果 |
| --- | --- | --- |
| ArkTS 构建 | `node scripts/build.mjs` | `BUILD SUCCESSFUL` |
| arm64 运行时 | 交叉编译 Node 24.22.1 / Bash 5.3 / toybox / libarchive / ripgrep | 全部产物随 HAP 打包 |
| Git 原生库 | `build_git.sh` 交叉编译 Git 2.56.0，静态链 zlib/PCRE2/OpenSSL/libcurl | `libgit.so`/`libgit-remote-http.so` 随 HAP 打包，导出 `iec_git_main`/`iec_git_remote_http_main`；宿主 musl 环境验证 HTTPS clone 成功 |
| 发布签名构建 | release 证书 + `PocketHarnessRelease` signingConfig | 签名 HAP 与 `.app` 均构建成功 |
| debug 签名构建 | U 盘 `PocketHarnessDebug` + `material/` | `entry-default-signed.hap` 构建成功，`hap-sign-tool verify-app` 通过，证书链与 U 盘 debug `.cer` 一致 |
| 上架包 | project 模式 `assembleApp` | `build/outputs/default/*.app`，`pack.info` 中 bundle 与版本一致 |
| release HAP 安装 | `hdc install` | 被拒：`9568322 signature verification failed due to not trusted app source`（发布签名不能侧载，符合预期） |
| 调试签名安装 | debug Profile + `hdc install -r` | `install bundle successfully`，`aa start` 后首屏渲染正常（本次改包名前） |
| 官方 Web GUI | 真机 | `dsh --profile web` 启动后 Web 组件加载出官方界面 |
| 冷启动首屏门控 | 真机 force-stop 后重新启动 | 启动页保持到会话/右栏出现后才撤掉；修正兜底计时后未再露出「选择一个工作区开始」的半成品页 |
| 冷启动性能 | 真机 force-stop 冷启动 + Node CPU profile | 可用时间约 11–15s（优化前约 50–55s）；`process.report.getReport()` 阻塞约 32s，短路后 `/api/session/create` 32.4s→约 0.3s |
| 原生终端 | 真机 | bash 正常启动；`pwd` 落在当前会话工作目录；`Ctrl-Z`/`fg` 作业控制可用 |
| 终端崩溃修复 | 真机 | `runtime-manifest.json` 给 bash/sh 补 `"arity": 3` 后不再 139 |
| 返回手势 | 真机 | 菜单 → 设置 → 右侧栏/终端 → 左侧抽屉逐层关闭；无浮层时交回系统 |
| 引用浮层 | 真机 | 「引用文本」按钮出现在选区下方 |
| 双指缩放 | 真机 | 已禁用 |
| fetch 补丁 | 真机终端 | JSON、gzip、FormData multipart、SSE、AbortError、外部 HTTPS 均通过 |
| 引擎插件表 | `bash scripts/check-engine-web.sh` | web profile 291 个插件，stderr 为空 |
| 引擎附件补丁 | `bash scripts/check-engine-archive.sh` | `attachment pure-JS fallback` 已写入归档；归档内 `dsh-attachment-local` 按文件头识别 PNG/JPEG/WebP/GIF 并原字节透传 |
| 真机附件上传 | 覆盖安装后经 ArkWeb 页面与 UI 文件输入实测 | pdf 与 png 上传均返回 `ok:true`；图片附件卡进入 ready 状态（不是 `upload.status === "error"`），移除按钮可用 |
| 运行时清单自动化 | `node scripts/runtime-manifest.mjs sync/check` | 按实际字节计算；重复 sync 结果不变；篡改 version 后 check 退出 1；构建出的 HAP 内清单为新版本 |
| 本次启动/清单改动编译 | `hvigor assembleHap` | `CompileArkTS`、`PackageHap` 通过；本机 `SignHap` 仅因未挂载签名 U 盘失败 |
| 宿主机测试 | `node scripts/test.cjs` | 39 项通过（含附件上传钩子、图片补丁与沙箱边界持久化的行为验证） |
| fetch 回归 | `node scripts/test-fetch-polyfill.cjs` | 15 项通过 |

## 未验收

- 首次安装/重解包提示：真机上确认安装后能看到「正在解包官方引擎与 npm」和首次启动说明，普通冷启动/未换运行时的覆盖升级不出现该提示；
- 新包名 `com.snoworwind.phoh` 的 debug Profile 侧载安装（需要重新生成自动签名）；
- Git 在 IEC 沙箱内的真机链路：`git clone/fetch/push` 的 HTTPS、CA bundle、`git-remote-https` 启动器与文件 shim（宿主 musl 验证不等同于鸿蒙设备）；
- 应用市场实际审核与上架；
- 后台保活：授权模糊定位后切后台/锁屏，引擎是否持续运行、通知栏行为与持续时间；
- 模型调用工具（`bash`/`rg`/文件工具）、工作区目录选择、文件上传、审批面板的完整链路；
- 附件消息回看与重启持久化：真机已验证上传与附件卡 ready，但尚未发送消息让模型读取，也未验证重启后历史附件仍可回看；
- 登录 / API Key 配置后的真实对话，以及各类网络环境下内置 CA 是否覆盖实际证书链；
- JIT-less V8 的长任务性能与内存占用。

## 新增命令的构建验证

本机（macOS + DevEco SDK 的 OHOS clang 15 cross target）已重新构建以下 IEC 命令对象，全部为 `aarch64-linux-ohos` 共享库，入口符号用 `llvm-nm -D` 核对：

| 组 | 命令 / 库 | 构建脚本 |
| --- | --- | --- |
| P0 | `python`/`python3`/`pip`（`libpython.so`）、`curl`、`ssh`/`scp`/`ssh-keygen`/`dbclient`、`sftp`、`jq` | `build_python.sh`、`build_curlcmd.sh`、`build_dropbear.sh`、`build_sftp.sh`、`build_jq.sh` |
| P1 | `diff`、`bc`、`nc`、`hexdump`、`less`/`more`、`vi`/`vim`、`gh`、`git-lfs` | `build_extra_commands.sh`、`build_bc.sh`、`build_less.sh`、`build_vim.sh`、`build_gh.sh`、`build_gitlfs.sh` |
| P2 | `openssl`、`tree`、`sqlite3`、`rsync`、`xz`/`unxz`/`xzcat`/`lzma`/`unlzma`/`lzcat`、`zstd`/`unzstd`/`zstdcat` | `build_opensslcmd.sh`、`build_tree.sh`、`build_sqlite3.sh`、`build_rsync.sh`、`build_xz.sh`、`build_zstd.sh` |

- 运行时清单 51 个启动器、34 个 `.so`；`node scripts/runtime-manifest.mjs check` 通过；
- `entry-default-unsigned.hap` 已在本地重新打包（约 299 MB），HAP 内清单与 34 个库一一对应；
- Python 3.12.14 静态模块包含 `_ssl`、`_sqlite3`、`_lzma`、`_ctypes`、`_curses`、`readline`；`python-stdlib.tar` 内含 pip/setuptools/wheel；
- Vim 9.1.1000 small + `vim-runtime.tar.gz`；`gh`/`git-lfs` 用 Go c-shared，只依赖 `libc.so`；
- **尚未在真机运行**：Go c-shared 的运行时初始化、Python 交互式 REPL、`ssh` 首次连接、`vim` 终端渲染等仍需设备验证；本轮按要求未连接手机、未推送远程。
- 调试证书签名已完成：`entry-default-signed.hap`（约 301 MB），`hap-sign-tool verify-app` 返回 `Verify success`，profile 与 `Pocket Harness DebugDebug.p7b` 逐字节一致；SHA-256 `2558ed9494db2793b5c4be2b69d1d9f52240a69b851c8300594b4af60b411226`。

## 已知缺口与假设

1. **两套 C++ ABI 怎么对齐**：`libiec_server.so` 由 hvigor 用 SDK 头文件构建、引用 `__n1`；交叉编译的产物必须用同名空间。V8 又需要 libc++ 22 的 `<ranges>`，做法是「libc++ 22 头文件 + `__config_site` 改成 `__n1`」，用 `scripts/probe-ranges-n1.sh` 验证过 ranges 能编译且 `-z defs` 链接随包 `libc++_shared.so` 全解析。
2. **引擎归档**只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与 `prebuilds/`，不按 `doc`/`locale`/`test` 目录名删除——这些文件在真机上确实会被用到。生成与校验见 `scripts/engine-prune/finalize-ship-list.sh`。
3. **追加进引擎树的三个原生插件**按运行期加载器的本地构建路径摆放（`node-addon-require-builtin/build/napi/…`、`@deepseek-ai/node-addon-system-linux-arm64/bin/{musl,gnu}/`、`node-pty/build/Release/`），两套 libc 目录各放一份。
4. **引擎需要可写的 `DSH_HOME`**（`filesDir/harness-home`）；只读目录会在插件挂载前失败。
5. 组件来源规则与逐项清单见 [组件来源](SOURCES.md)。
6. **解包期间 UI 会停顿**：`unpackResource()` 是同步调用，启动页能显示「正在解包」，但进度圈动画会停住；要让动画持续需要把解包移出 UI 线程或增加原生进度回调。
7. **运行时清单自动化只覆盖命令行构建**：直接使用 DevEco IDE 的 Build 不经过 `scripts/build.mjs`，不会执行 sync/check；发布构建应统一使用 `build.mjs`，或给 hvigor 增加预构建任务。
8. **`runtime-preload.cjs` 会改变无参 `process.report.getReport()` 的返回**：应用运行时里无参调用只返回 `{ header: {} }`，用于跳过约 30s 的 CPU/network 枚举；需要完整诊断报告时设 `DSH_LITE_REPORT=0`。带 options 的调用不受影响。

## 2026-11-17 设备测试报告修复

设备测试（`pocketharnessohos测试结论.docx`，运行时 0.2.2-rc.1）列出的问题及本轮处理：

| 报告项 | 根因 | 修复 | 本轮验证 |
| --- | --- | --- | --- |
| `rg` 任何参数都报 `requires at least one pattern`（P0） | `iec_rg_main` 忽略 `_argc/_argv`，CLI 解析读 `std::env::args()`；dlopen 后那是宿主 argv | `scripts/rg/build-ripgrep.sh` 让解析器读 IEC 传入的参数 | 重建 `librg.so`（OHOS aarch64，4.9 MB）；同一补丁的宿主 `.so` 用 ctypes 调用：pattern/no-match/`--version`/`--files`/`-c` 全部通过 |
| `gh`、`git-lfs` dlopen 失败，退出码 125（P1） | stock Go 的 c-shared 用 initial-exec TLS（`R_AARCH64_TLS_TPREL64`），鸿蒙 musl 拒绝 | 改用 OpenHarmony Go 工具链（`GOOS=openharmony`，TLSDESC）；新增 `fetch_go_ohos.sh`，构建脚本强制 `GOTOOLCHAIN=local`、固定 tag 并检查产物无 TPREL | 重建 `libghcmd.so`（43 MB）与 `libgitlfscmd.so`（13.6 MB）：`R_AARCH64_TLSDESC`、无 TPREL、`NEEDED` 仅 `libc.so`、入口符号存在。未在真机跑 `gh`/`git lfs` 业务 |
| `openssl req`/`ca` 失败（P2） | `OPENSSLDIR` 编进了构建机路径 | `--openssldir=/etc/ssl`；随包 `harmony/openssl.cnf` 落到 `<sysroot>/certs/openssl.cnf`，`OPENSSL_CONF` 指向它；建好 `ca` 目录/index/serial | 重建 `libopensslcmd.so`；`libcrypto.a` 内已无 `/Users`、`/mnt/d` 路径，含 `/etc/ssl` |
| `python3 -m venv` 失败、`_bz2` 缺失（P2） | 构建时删掉 `ensurepip`；没有 `libbz2` | 保留 `ensurepip` 并补 `_bundled` pip wheel；新增 `build_bzip2.sh` 供 `_bz2`；清理 `._*` | 只改了脚本，**本轮未重建 `libpython.so`**（构建机缺 host python3.12），需在构建机重跑 `build_python.sh` |
| `tar -cjf`/`-cJf` 失败（P3） | libarchive 没编 bzip2/xz/zstd 后端 | `build_libarchive.sh` 静态链四个编解码器 | 重建 `libarchive.so.13`、`libbsdtar.so`、`libbsdcpio.so`、`libbsdunzip.so`、`libzipcmd.so`；符号表确认 `archive_liblzma_version`/`libzstd`/bz2 filter 均在 |
| `zip -v`、`unzip -v` 不支持（P3） | 前端没有 `-v` | `zip_entry.c` 处理 `-v/--version/--help`；新增 `unzip_entry.c` 包住 bsdunzip：`-v` 无归档时打印版本，有归档时映射到 `-l` | 宿主用 stub libarchive 跑过 `-v`、`--version`、`-v a.zip`、`-qv a.zip`、`-d out -v a.zip`、`-l` |
| `diff --version` 报错（P3） | 直接转发给 `git diff`，git 不认识 | `cmd_diff.c` 自己回答 `--version/-v` 与 `--help/-h` | 宿主编译验证：两开关退出 0，正常比较/`-q`/`-s` 行为不变 |
| `node-pty` 在 IEC shell 内 `forkpty` 失败（P3） | 沙箱不允许 `fork`；tty shim 只能接管 pty fd/RPC | 未改代码，记为已知限制（见 `ARCHITECTURE.md`） | — |

本轮构建在 WSL Ubuntu 上完成（OHOS clang 15 + sysroot），未连接真机、未推送远程。`gh`/`git-lfs` 的 `GOOS=openharmony` 产物只做了 ELF/符号层验证，业务链路仍需真机复测；`libpython.so` 需要在有 host python3.12 的构建机重编后才能随包升级。

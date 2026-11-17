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

## 2026-11-17 第二次修复（账号页白屏 / 文件下载）

| 问题 | 根因 | 修复 | 验证 |
| --- | --- | --- | --- |
| 下载 agent 交付的文件没有反应 | 官方 GUI 的「下载」把文件读成 `blob:` 后点 `<a download>`；ArkWeb 没有下载委托，blob 下载被静默丢弃 | 文档起点注入桥脚本接管 `<a download>`（含 `anchor.click()`）与 `onDownloadStart`，字节经 `javaScriptProxy` 分片（256 KiB）交给壳层，`DocumentViewPicker` 落盘 | 桥脚本在 Node + 假 DOM 下验证：blob 锚点被拦截、原点击被抑制、600 KiB 文件切成 4 片并原样重组；下载名取自 `download` 属性 |
| DeepSeek 账号点「查询用量」白屏、退不出去 | 该链接是 `<a target="_blank">`；`multiWindowAccess(false)` 下没有新窗口处理器会挂住渲染进程，轮询停止后返回手势仍被残留的对话框状态吃掉 | 捕获阶段拦下所有 `target=_blank`：站外转系统浏览器、站内就地导航；`onLoadIntercept` 只放行本地 origin；`onBackPress` 在 2.5 s 没有页面采样时忽略残留浮层，并把跑出站外的页面拉回本地 | 桥脚本验证：`platform.deepseek.com` 触发 `openExternal`、站内 `_blank` 就地导航、普通链接不受影响；未在真机复测账号页 |
| 不该伪造 `window.dshDesktop` | 引擎用 `"dshDesktop" in globalThis` 判断桌面版，会改变 onboarding / 转写视图 / 拖拽 / 分析等行为 | 改为只做 DOM 层拦截，不注入 `dshDesktop` | 桥脚本断言 `dshDesktop` 不存在 |

本轮只改 ArkTS 与文档，未重建原生库、未连接真机、未推送远程。

## 2026-11-17 用 release 资产补全本地构建

本机此前只有一部分原生库（缺 libpython/libgit/libcurl 等 15 个）。从 v0.1.0.2 的
`pocket-harness-native-arm64-v8a.zip` 与 HAP 资产补齐后，本地可以构建完整包：

- 原生库：只补缺失的 15 个（libpython、libgit、libgit-remote-http、libcurlcmd、
  libjqcmd、libbccmd、libdropbear、libsftpcmd、liblesscmd、libvimcmd、libtreecmd、
  libsqlite3cmd、librsynccmd、libxzcmd、libzstdcmd）；本轮修过的 `librg.so`、
  libarchive 前端、`libopensslcmd.so`、`libghcmd.so`、`libgitlfscmd.so` 保留本机构建，
  没有被旧资产覆盖。
- 运行时归档：从 release HAP 取回 `npm.tar.gz`、`python-stdlib.tar`、
  `vim-runtime.tar.gz`，放进 `entry/src/main/resources/rawfile/tools/`。
- Python：`python-stdlib.tar` 里补回 CPython 3.12.14 的 `ensurepip` 与
  `pip-25.0.1` wheel，`python3 -m venv` 不再报 `No module named ensurepip`；
  `_bz2` 仍编在 `libpython.so` 里，要等重建 Python 才能补上。
- 构建：`node scripts/build.mjs` 重算清单为 `0.2.2-rc.1-79f47bdf59e8`，
  `assembleHap` BUILD SUCCESSFUL，产出签名的 `entry-default-signed.hap`（303 MB）。

本轮未连接真机、未推送远程。

## 2026-11-17 运行时二进制遗留问题（BINARY-FIX-REMAINING）

对照真机复测报告 `BINARY-FIX-REMAINING.md`（运行时 `0.2.2-rc.1-79f47bdf59e8`）逐项处理。
本轮在 WSL 上重建了 `libpython.so`、`librg.so`、`libghcmd.so`、`libgitlfscmd.so`、`pty.node`
并重新算出清单 `0.2.2-rc.1-4efcf73f4e8a`；宿主测试覆盖路由、启动器与 stdlib 定位，真机完成了覆盖安装、
首次解包、Web GUI 启动与 `git lfs` 验收。

| 报告项 | 根因 | 修复 | 本轮验证 |
| --- | --- | --- | --- |
| `git lfs` 不能调 `git`（P1） | 沙箱拒绝执行任何 ELF：`execve` 对 `bin/git`、bundle libs 里的桩、`/lib/ld-musl-aarch64.so.1` 全部返回 `EACCES`；文本启动器返回 `ENOEXEC` 是因为格式检查先于该拒绝。Go 的 `os/exec` 因此无法启动命令 | 编译 `git-lfs` 时打补丁（`scripts/optional/gitlfs-ohos/` + `tools/iec_fork_exec.c`）：cgo 里 `fork()`，子进程只跑 C 代码并调用链接进来的 `exec/shim.c` 走 IEC 执行服务、成为替身；Go 侧照常 `waitpid`/读管道。`subprocess.Cmd` 对 `$IEC_SYSROOT/bin/*` 的启动改走这条桥 | 真机：`git lfs env` 输出 `git version 2.56.0`；`git init` + `git lfs install --local` + `git lfs track '*.bin'` 后 `.gitattributes` 为 `*.bin filter=lfs diff=lfs merge=lfs -text` |
| `python3 -m venv` 失败（P1，根因 A） | venv 的子进程会删 `PYTHONHOME`，而 stdlib 只在 `<sysroot>/python/lib`，`<sysroot>/lib/pythonX.Y` 不存在 | `python-stdlib.tar` 增加 `lib/python3.12 -> ../python/lib/python3.12`（设备上落成 `.IEC_SYMLINK`，由 fs shim 解析）；`venv` 的 CLI 默认（POSIX 上 `--symlinks`）与 `EnvBuilder` 默认一起改成复制启动器；`build_python.sh` 把兼容链接打进归档并强制校验 `_bz2` | 宿主用同一版 CPython 搭 `<prefix>/bin/python3` + `lib/python3.12` 兼容链接，并按同样的补丁改 venv：`env -u PYTHONHOME` 下 venv 创建成功、`bin/python*` 全是普通文件（无符号链接），venv 内解释器 `sys.prefix` 正确且能找到 stdlib；真机复测通过（报告确认） |
| 符号链接启动器不能执行（P1，根因 B） | 服务端只按字面路径判 kind，`.IEC_SYMLINK` 标记文件对内核不可见 | `exec/path_resolver.cpp` 新增 `ResolveLaunchPath()`：逐段跟随真实符号链接与 `.IEC_SYMLINK`，在 `onExecute`/`Spawn`/`SpawnShebang` 三处生效 | 宿主自测 5 项：标记链接、真实链接、普通文件、`/proc` 路径、经链接判为 kSo；真机 `ln -s`/`env`/`spawnSync` 复测通过（报告确认） |
| `_bz2` 缺失（P2） | `build_python.sh` 没有把 `libbz2` 交给 configure，CPython 静默丢弃 `_bz2` | configure 传 `LIBS=-lbz2`（依赖由 `build_bzip2.sh` 提供），并在配置后把 `_bz2` 缺失变成硬错误 | 重建 `libpython.so`：`PyInit__bz2` 导出、`BZ2_bzCompress` 已链入；`NEEDED` 只有 `libc.so`；产物 strip 后 14.1 MB；真机 `import bz2` 复测通过 |
| `node-pty` `forkpty/openpty` 失败（P3） | node-pty 直接调 libc；`posix_openpt` 未接管，`/dev/ptmx` 在沙箱不可开 | `tty/shim.c` 新增 `posix_openpt`；`scripts/pty/build-node-pty.sh` 把 tty+exec shim 编进 `pty.node`，用 `--wrap` 改掉 `forkpty/openpty/posix_openpt/execvp` 等调用 | `pty.node`（96 KB）导出 `__wrap_forkpty/__wrap_openpty/__wrap_posix_openpt/__wrap_execvp`，无 `U forkpty/openpty`；`NEEDED` 仅 `libc++_shared.so`/`libc.so`；已替换进引擎归档；真机 `pty.spawn` 输出 `PTYOK`（报告确认） |
| `git init` 模板警告（P3） | 假根没有 `/usr/share/git-core/templates` | 启动时建 `<sysroot>/git-templates/{hooks,info,branches}`，环境变量 `GIT_TEMPLATE_DIR` 指过去 | 真机 `git init` 不再警告（报告确认） |
| `gh --version` 显示 `DEV`（P3） | c-shared 构建里 `build.Version` 默认 `DEV`，无法从 build info 恢复 | `build_gh.sh` 用 `-ldflags -X .../internal/build.Version=$GH_VERSION`（默认 tag）与 `Date` | 重建 `libghcmd.so`（43 MB），真机输出 `gh version 2.100.0`（报告确认） |
| `rg` 无 PCRE2（P3） | 构建没开 `pcre2` feature | `build-ripgrep.sh` 支持 `PCRE2=1`，用 `scripts/optional/build_pcre2.sh` 产的静态 `libpcre2-8.a`（JIT off）通过 pkg-config 链入，并 strip | 重建 `librg.so`（5.2 MB）：`iec_rg_main` 导出、含 77 个 `pcre2_*` 符号、无未解析项；真机 `rg -P` 复测通过 |

宿主测试入口：

```bash
bash native/iec/scripts/test_iec_native_host.sh   # 45 + 15 项，含 sidecar/符号链接路由
```

产物变化：`entry/libs/arm64-v8a/libpython.so`（14.1 MB，含 `_bz2`）、`librg.so`（5.2 MB，含 PCRE2）、
`libghcmd.so`（43 MB，版本号已注入）、`libgitlfscmd.so`（13.6 MB，含 IEC 执行桥）；
`python-stdlib.tar` 增加 `lib/python3.12` 兼容链接，`official-engine.tar.gz` 内 `pty.node` 已替换。

### 平台 exec 限制与 git-lfs 执行桥（2026-11-17 深夜）

- 平台实测：应用进程里 `execve` 任何 ELF 都被拒绝（`EACCES`）——`bin/git`（应用数据目录）、
  `entry/libs` 里的 `libgitlaunch.so`（bundle el1）、系统动态链接器
  `/lib/ld-musl-aarch64.so.1` 全部如此；文本启动器返回 `ENOEXEC` 只是因为格式检查先发生。
  所以“ELF 启动桩 / 动态链接器加载”两条路都不可行（中途版本已在真机证伪并回退）。
- 最终修复：`git-lfs` 用**进程内 fork + IEC 执行桥**
  （`native/iec/scripts/optional/gitlfs-ohos/`、`native/iec/tools/iec_fork_exec.c`），
  `subprocess.Cmd` 对 `$IEC_SYSROOT/bin/*` 的启动全部走这条桥（`git`、`ssh` 等）。
- 真机验证（覆盖安装）：启动探针 `git lfs env` 输出 `git version 2.56.0`；
  `git init` → `git lfs install --local` → `git lfs track '*.bin'` 成功，
  `.gitattributes` 内容为 `*.bin filter=lfs diff=lfs merge=lfs -text`。
- `gh`：`internal/run.PrepareCmd` 已接到 `internal/ghohos`（同一套 fork + exec shim），
  `git.Client.Command` 的 `Run`/`Output` 都走它。真机验证：`gh auth setup-git --force
  --hostname github.com` 退出 0（内部执行了 `git config`），不再出现
  `fork/exec .../bin/git: permission denied`。

### 真机覆盖安装与首次解包（2026-11-17 晚）

- 覆盖安装：`hdc install -r entry-default-signed.hap` → `install bundle successfully`；真机
  安装后应用版本 `0.1.0.2`（versionCode 3），应用数据保留。
- 发现并修复：新运行时版本的首次启动会在 UI 线程同步读 rawfile（约 84 MB，HAP 内压缩）
  并解包（约 8 秒），触发 `THREAD_BLOCK_6S` 看门狗把进程杀掉（真机复现）。现在
  `unpackResource()` 返回 Promise：rawfile 读取与 tar 解包都在 NAPI 工作线程，
  `ensure()` 里 4 处调用改为 `await`。
- 修复后真机复测：engine 解包 20:49:33.817 → 20:49:41.734，stdlib/vim 至 20:49:45.322，
  共约 11.5 秒，流式 hilog 中无 `THREAD_BLOCK`/`APP_FREEZE`；20:49:48 `bin/node` 启动，
  `http://127.0.0.1:40085` 加载出官方 Web GUI，进程 50 秒后仍存活。

### web_fetch 的 undici 覆盖（2026-11-17 深夜）

- 症状：`web_fetch` 对任意 URL 稳定报 `TypeError: fetch failed`；`web_search`、页面 `/api`、终端里的 `node -e "fetch(...)"` 都正常。
- 根因：`@deepseek-ai/dsh-web-fetch-http` 的 `requestOnce()` 用 `await import("undici")` 而不是 `globalThis.fetch`；undici 在响应解析阶段依赖 WASM（llhttp），而 Node 以 `--jitless` 运行，`WebAssembly` 为 `undefined`。
- 修复：`harmony/fetch-polyfill.cjs` 在 `Module._load` 返回 CJS 导出之前把 `undici.fetch` 换成补丁实现（ESM 命名空间是加载时快照，import 后再改 exports 不生效）；只改 `fetch`，`Agent`/`Pool`/`ProxyAgent` 保持原样，避免破坏 `dsh-http-proxy`。
- 回归：`scripts/test-fetch-polyfill.cjs` 新增“假 undici 模块 + 真实请求”用例（16 项 ALL PASS）；`scripts/test.cjs` 51 项通过；`runtime-manifest.mjs check` 不变（`rawfile/harmony` 不计入清单）。
- 验证：设备内 agent 用同一补丁确认 `web_fetch https://example.com/` 通过；本仓库 HAP 待重装复核。

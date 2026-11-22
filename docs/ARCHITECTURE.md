# 架构与扩展

```text
ArkUI Index（只留一个 Web 组件 + 启动状态）
  └─ NativeRuntime
      ├─ IEC HAR（libiec_server.so）── execStart/execPoll/execWrite/unpackResource
      │     └─ 原生子进程：bash / node / toybox / tar / unzip / rg / git / python / curl / ssh / jq / less / vim / gh / git-lfs 等
      └─ node bin.js --profile web --port 0 --no-open
            ↕ HTTP + SSE/WebSocket（仅 127.0.0.1）
          Web 组件加载 dsh 打印的 http://127.0.0.1:<port>/?token=…
```

界面不是自己画的：HAP 里没有会话气泡、审批面板和终端页，只有官方 `@deepseek-ai/dsh` 的浏览器前端。Agent Loop、工具注册、审批、会话存储、工作区浏览、设置页全部由官方 Web GUI 提供；只有**侧栏终端**由本工程用 libvterm 原生绘制。本工程负责四件事：把官方引擎解包到应用沙箱、起一个只监听回环地址的 `dsh web`、用 Web 组件把它显示出来、在右侧栏 tab 的位置叠加原生终端。

## 启动时序

`Index.aboutToAppear()` → `NativeRuntime.startWebUI()`：

1. `ensure()`：读 `rawfile/tools/runtime-manifest.json`，校验每个命令的 `.so` 已随包安装；
2. `initIecResourceManager` + `probeCaps()`：确认设备允许创建原生子进程，不允许就直接报错，不做降级运行时；
3. `startIecServer()`：启动执行/终端服务；
4. 首次安装时把 `rawfile/tools/official-engine.tar.gz` 解到 `filesDir/runtime-<version>/engine`，把 `tools/npm.tar.gz` 解到运行时根；启动器、CA、预加载补丁全部落盘后才写 `.installed`（JSON：版本号 + 关键文件 SHA-256 + 清单摘要）；解包是同步阻塞调用，动手前先经 `onInstalling` 回调把「正在解包」交给界面并让出一帧，否则 300ms 轮询永远观察不到 `installing=true`，首次启动提示不会出现；
5. 为每个命令写 `#IECSOv2` 启动器到 `runtime-<version>/bin`，toybox 的 applet 也逐个写；
6. 合并 CA bundle（Mozilla 根证书 + 可选附加 CA），构造环境变量；
7. 起 `node <engine>/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --port 0 --no-open`，从 stdout 里取出 `dsh web: <url>` 那一行；
8. 把这个 URL 交给 `Web` 组件。URL 带一次性 `?token=`，服务端用它换 cookie 后重定向到干净的 `./`；
9. **首屏门控**：`onPageEnd` 只说明静态资源加载完，此时官方前端还在恢复工作区/会话，输入框会被禁用以「选择一个工作区开始」，右栏也还没渲染。原生启动页继续盖住 Web，`Index.startUiWatch()` 每 500ms 检查 `[data-conversation-session]`，看到首个会话挂载后才撤掉启动页；兜底从官方首页挂载后开始计时（60 秒），另有 120 秒绝对兜底；页面已报错时不放行。

端口用 `0` 让内核挑，避免和其他进程抢固定端口；`--no-open` 阻止引擎试图拉起系统浏览器。

## 进程与文件

```text
filesDir/runtime-<engineVersion>-<内容摘要>/{bin,engine,certs,home,tmp}
filesDir/harness-home/          DSH_HOME：profile、会话 JSONL、设置、凭据都写在这里
```

- 运行时目录名、版本自动化和 `.installed` 校验见下文「启动页与阶段提示」「运行时版本自动化」两节。
- 目录被改坏时的恢复分三层：三项存在性探测失败 → 整棵重解；引擎启动报 `Cannot find module` / `failed to import` → 自动重解一次（`NativeRuntime.repair()`）；仍失败 → 界面提供「重新解包运行时」按钮。`repair()` 只删 `runtime-*`，不碰 `harness-home`。
- `harness-home` 永不被应用删除：覆盖升级保留会话与设置，卸载才清空。
- 启动时会往 `harness-home/AGENTS.md` 写入一份内置全局说明（源文件是 `rawfile/agents/AGENTS.md`，每次启动覆盖）；DSH 把它作为用户级指令加载进每个会话，用户规则应写在工作区的 `AGENTS.md`。

- 解包用的是 HAR 里的 `unpackResource()`：先把 rawfile 读进内存，再用 libarchive 的 write-disk 解到目标目录。它是异步的（返回 `Promise<number>`）：rawfile 读取与解包都在 NAPI 工作线程，首解包约 11 秒也不会阻塞 UI 线程——同步做过一次，`THREAD_BLOCK_6S` 看门狗会在解包结束时把进程杀掉。`libarchive.so.13` 是运行期 `dlopen` 的共享库，必须随 HAP 打进 `libs/arm64-v8a/`。
- 解包失败会留下半棵树，所以失败时清掉 `engine/` 再抛出；`fs.mkdirSync` 在目录已存在时会抛 `13900015 File exists`（即使 `recursion=true`），所以所有建目录都先 `accessSync` 判断。

### 启动页与阶段提示

`Index` 用一个 `webReady` 状态控制原生启动页，按三段时间推进：

1. **运行时准备**：`NativeRuntime.ensure()` 检查 manifest、原生工具、IEC 能力和 `.installed`。需要解包时，先经 `onInstalling` 回调把「正在解包」状态交给界面，`await` 一帧后才执行同步的 `unpackResource()`；否则 300ms 轮询永远看不到 `installing=true`，首次启动提示不会出现。
2. **Web 服务启动**：启动 Node、从 stdout 抓 `dsh web: <url>`，状态变为「正在启动官方 Web 服务」。
3. **首屏门控**：`onPageEnd` 只代表静态资源加载完，官方前端还在恢复工作区/会话，输入框此时是 `inert` 的「选择一个工作区开始」，右栏也还没渲染。启动页继续盖住 Web（`HitTestMode.Block`），`startUiWatch()` 每 500ms 检查 `[data-conversation-session]`，首个非空会话挂载后才撤掉启动页。兜底不能从 URL 就绪时开始计时：冷启动的 Node/JITless 与插件加载本身可能超过 20 秒，过早放行会露出「选择一个工作区开始」的半成品页。现在的兜底是「官方首页挂载后 60 秒仍无会话」才放行，另有 120 秒绝对兜底处理 WebView 完全挂死；`failed` 非空时都不放行。

| 场景 | 启动页表现 |
| --- | --- |
| 首次安装 / 清数据 / 运行时变化 | 显示「正在解包官方引擎、Python 与 Vim」和首次启动说明；解包期间 UI 线程被同步调用占住，进度圈可能停住，但文字提示保留 |
| 覆盖升级但 manifest 版本未变 | 与普通冷启动相同，不出现解包提示；这是复用旧运行时的正确行为 |
| 普通冷启动 | 「正在启动本地运行时…」→「正在启动官方 Web 服务」→「正在恢复上次会话与工作区…」，首个会话挂载后显示界面 |

本机优化后普通冷启动到可用约 **11–15 秒**；首次安装额外解包约 46 MB 引擎、24 MB Python 标准库与 10 MB Vim 运行时，不计入这个数字。定位过程：Node CPU profile 显示 `process.report.getReport()` 占约 32 秒，短路后 `/api/session/create` 从 32.4 秒降到约 0.3 秒。

### 运行时版本自动化

`scripts/runtime-manifest.mjs` 是唯一的摘要实现：

- 输入：`engineVersion`、`nodeVersion`、按命令名排序的 `commands`，以及四个运行时归档
  （+ 可选 ELF 启动桩）的字节——哈希在构建/打包时临时计算，不写进清单；
- 输出：`<engineVersion>-<sha256 前 12 位>`，写回
  `entry/src/main/resources/rawfile/tools/runtime-manifest.json` 的 `version`；
- 摘要域只覆盖**会被解包进 `runtime-<version>/` 的东西**：
  `official-engine.tar.gz`、`npm.tar.gz`、`python-stdlib.tar`、`vim-runtime.tar.gz`；
- `entry/libs/<abi>/*.so` 不计入：`.so` 直接从 HAP 的 `libs` 加载，启动器每次
  `ensure()` 都按 `commands` 重写，原生库变化不需要换运行时目录；而且 hvigor
  打包会 strip 它们，构建树里的字节本来就不是设备字节；
- 壳层插件（`plugins/harmony-compat`、终端插件）不计入：随 rawfile 分发、每次启动
  重新同步，`pack-native.sh` 也不再把它们打进引擎归档；
- 校验只在有归档的机器上有意义（打包机 / 本地构建）；clean checkout 上 `check` 会跳过并
  提示到打包机执行。发布时 `--strict-runtime-manifest` 会拒绝“清单与归档不一致”的包；
- 不包含应用 `versionName`：只改 ArkTS/UI 时复用旧运行时；
- 不包含绝对路径：换构建目录或构建机不会误换版本。

工作流：

```bash
# 生成归档后（pack-native.sh 末尾会自动调用）
node scripts/runtime-manifest.mjs sync

# 只校验，不写回；CI/发布门禁用
node scripts/runtime-manifest.mjs check

# 发布构建：清单与本次产物不一致时直接失败
node scripts/build.mjs --strict-runtime-manifest --deveco-home "<DevEco>"
```

`scripts/build.mjs` 默认在 hvigor 前执行 `sync`，`pack-native.sh` 也调用同一脚本，不再手算摘要；因此 `pack-native.sh` 现在要求构建机有 Node 18+。设备端 `ensure()` 读取 `.installed`（JSON，schema 2）：版本号必须等于当前 `manifest.version`，并对 `bin/node`、`bin/bash`、引擎 `bin.js`、npm CLI、Python stdlib 入口重算 SHA-256、核对随包清单摘要；任何不一致或旧格式标记都按未安装处理，整棵重解 `runtime-<version>`，不触碰 `harness-home`。同 UID 可改写 `.installed` 与运行时，因此这层校验只发现“只改文件、不改标记”的意外损坏或部分篡改，边界见 [SECURITY.md](SECURITY.md)。

注意：直接点 DevEco IDE 的 Build 不经过 `build.mjs`，不会自动 sync/check。发布流程应统一走命令行入口，或后续给 hvigor 增加预构建任务。

## 官方 Web 服务

- `--profile web` 首次运行会在 `$DSH_HOME/profiles/web/` 生成 `package.json`、`cordis.patch.yml` 和 `pnpm-workspace.yaml`，**不安装任何依赖**：bundle 从安装目录的 `node_modules` 解析。
- 引擎归档按 sdk profile 的插件表裁剪过，但包含了 web profile 需要的全部插件（`dsh-web-app`、`dsh-host-webserver`、`dsh-host-frontend-static`、`dsh-web-frontend` 与整套 `dsh-client-ui-*`）。`scripts/check-engine-web.sh` 用宿主 Node 跑 `--profile web --dump-config` 验证这一点：291 条插件、stderr 为空。
- 服务只绑 `127.0.0.1`，浏览器信任围栏接受回环地址；不要改成 `0.0.0.0`，那会把执行能力暴露到网络。

## 原生执行

IEC 的 `execStart` 拿到的不是普通 `fork`：鸿蒙应用进程不能直接 `fork/exec`，`.so` 由原生子进程装载，`.so` 里导出 `iec_bash_main` / `iec_node_main` 之类的 C 入口。命令行启动器是一个文本包装文件，记录目标 `.so`、入口符号和启动方式（本工程统一用 `2`，即鸿蒙原生子进程）。

启动器默认是 `#IECSOv2` 文本文件。代码里还保留 sidecar 形态（`bin/<name>` 是 ELF、启动器放 `bin/<name>.iecso`）的识别，但真机证明平台拒绝应用进程 `execve` 任何 ELF（应用数据目录、bundle libs、甚至系统动态链接器全部返回 `EACCES`），所以没有任何命令使用它；Go 程序需要执行命令时走下面「Go 命令」一节的进程内执行桥。

符号链接也由服务端解析：真实链接用 `readlink`，沙箱里 fs shim 生成的 `<name>.IEC_SYMLINK` 标记文件按同样语义跟随（`exec/path_resolver.cpp` 的 `ResolveLaunchPath()`），所以 `ln -s <sysroot>/bin/ls myls` 和默认 venv 的 `bin/python` 都能执行。

`libnode.so` 重链接时用 `--wrap` 把 exec 家族换成了 IEC 的 RPC 版本（导出 64 个 `__wrap_*`），所以官方引擎里的 `child_process`（工具调用、终端、子代理）在设备上落到执行服务。`fork` 本身没有被拦截，是否允许由设备决定，`probeCaps().fork` 会先探测。`node-pty` 的 `pty.node` 用同一套 tty/exec shim 重新链接（`scripts/pty/build-node-pty.sh`）：`pty.cc` 里的 `forkpty/openpty/posix_openpt/execvp` 被 `--wrap` 换成服务端实现，因此它拿到的 master/slave 是 IEC 的虚拟 PTY，而不是沙箱里打不开的 `/dev/ptmx`。

**Git**：`libgit.so` 用同一套 `--wrap` shim 接管文件与进程调用，静态链接 zlib/PCRE2；`libgit-remote-http.so` 额外静态链接 libcurl/OpenSSL，因此运行时只依赖 `libc.so`。`GIT_EXEC_PATH` 指到 `<sysroot>/bin`，`GIT_SSL_CAINFO` 指到合并后的 CA bundle，HTTPS 不做任何证书放宽。`git init` 的模板目录由启动时创建的 `<sysroot>/git-templates` 提供（`GIT_TEMPLATE_DIR`），不再警告缺模板。`git-lfs` 自己不 `execve` `git`：`subprocess.Cmd` 对 `$IEC_SYSROOT/bin/*` 的启动走`native/iec/tools/iec_fork_exec.c` 的 fork + IEC 执行桥，所以 `git lfs install/track/env` 能正常拿到 `git version`/`git config`；`gh` 同理，`internal/run.PrepareCmd` 已接到 `internal/ghohos`（同一套桥），`git.Client.Command` 的 `Run`/`Output` 都走它。

**Python**：stdlib 装在 `<sysroot>/python/lib/python3.12`，`PYTHONHOME=<sysroot>/python`。venv 的子进程会主动删掉 `PYTHONHOME`，所以 `python-stdlib.tar` 里还带一个 `<sysroot>/lib/python3.12 -> ../python/lib/python3.12` 的兼容链接（设备上落成 `.IEC_SYMLINK`，由 fs shim 透明解析）；venv 默认改为复制启动器而不是建符号链接。`_bz2` 与其余静态扩展一起编进 `libpython.so`。

**libc++ ABI**：随 HAP 打包的 `libc++_shared.so` 来自 DevEco SDK，只导出 `std::__n1` 命名空间的符号。所以所有 C++ 产物（`libnode.so`、`pty.node`、`require_builtin.node`）都必须用「libc++ 22 头文件 + `_LIBCPP_ABI_NAMESPACE __n1`」编译：V8 需要 libc++ 22 的 `<ranges>`，而 SDK 自带那套 `__n1` 头文件太旧、没有 ranges。用默认 `__1` 头文件编出来的 `.so` 在真机上 dlopen 会报 `_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`。

## 后台保活

鸿蒙会把切到后台的应用进程冻结，Web 界面背后的 dsh 引擎也跟着停，正在跑的 Agent 轮次就断在半路。做法照 HiSH：`platform/BackgroundKeepAlive.ets` 在界面加载完成后申请「模糊定位」，订阅 `locationChange`，再起一个 `BackgroundMode.LOCATION` 的连续任务（`backgroundTaskManager.startBackgroundRunning`）。这样应用在后台被当作前台服务对待，引擎和 WebSocket 都还活着。

需要三样东西，缺一不可：

- `module.json5` 的 `requestPermissions`：`ohos.permission.KEEP_BACKGROUND_RUNNING`、`ohos.permission.APPROXIMATELY_LOCATION`（带 reason/usedScene）、`ohos.permission.LOCATION_IN_BACKGROUND`；
- `abilities[].backgroundModes: ["location"]`；
- 用户授权模糊定位；被拒绝时保活直接跳过（`start()` 返回 false），不影响前台使用。

Windows 版的 DSH 退出时会停引擎；这里反过来——`aboutToDisappear` 才停 Web 服务与连续任务，切后台不停。

## 文件与安全边界

官方 Web GUI 直接暴露官方引擎的能力面：工作区选择、文件读写、终端、命令执行。真正的能力闸门仍是引擎的 permission preset / 工具开关（默认 `workspace-write + ask`）；引擎自带沙箱（bwrap / Landlock）在鸿蒙上大概率不可用，探测失败返回 `SANDBOX_UNAVAILABLE`。壳层在此之上收口 Web 侧入口：

1. 服务只监听回环地址；WebView 只加载本地 origin，主框架导航、文档起点脚本与 `javaScriptProxy.permission` 都限定在当前 `http://127.0.0.1:<port>`，`fileAccess`/`databaseAccess` 关闭；
2. 页面 → 壳层的终端/下载桥要求本次启动的 nonce（`window.__dshNonce`，随机 UUID），消息与下载任务 id 都校验；下载分片另有单分片/总字节/任务数/超时配额；
3. 执行服务校验调用者：`SO_PEERCRED` 不可用时拒绝，TTY 绑定创建者，延迟 kill 前比对进程 `starttime`；归档解包对越界硬链接/符号链接 fail-closed；
4. 日志（壳层 `dsh.log` 与原生 `iec-*.log`）写盘前脱敏并按大小轮转；`.installed` 抽查关键文件 SHA-256；
5. release 构建关闭 WebView 调试，`pages/KbTest` 调试页已移除。

**同 UID 即信任**：引擎、插件、Agent 命令与壳层同沙箱，能执行命令的一方可以读写运行时目录并改写 `.installed`；完整性抽查不抵御同 UID 主动攻击。第三方插件没有权限沙箱。完整信任假设与接受风险见 [SECURITY.md](SECURITY.md)。

## 客户端插件与返回手势

两个客户端插件，职责分开：

- `@local/dsh-harmony-terminal`（`plugins/dsh-harmony-terminal`）：注册右侧栏终端 tab、上报 stage 矩形、`open/close/focus`，并从 `/api/session/list` 取当前会话的 `cwd` 下发，终端据此 `cd`。
- `@deepseek-ai/dsh-harmony-compat`（`plugins/harmony-compat`）：鸿蒙平台适配——用 `MutationObserver` 采样左抽屉（`aria-modal`）、设置对话框（`role=dialog`）、菜单（`role=menu`）、右栏（`收起右侧边栏` 是否可见），变化时立即用 `DSH_TERM:<nonce>:{op:'ui'}` 推给壳层；同时把选区「引用文本」浮层按 `offsetParent` 移到选区下方。两个插件的桥消息都只从主框架发出，并带文档起点注入的 nonce。

`Index.onBackPress()` 按浮层优先级消费返回：菜单 → 设置对话框 → 右侧栏/终端 → 左侧抽屉 → 系统。状态来自插件的 `ui` 推送，另有一个 500ms 轮询兜底，避免动画窗口期内误判。

## 运行时补丁

- **启动性能**：`node-addon-native-custom-loader` 在 OHOS 上无法从 ELF interpreter / `/proc/self/maps` 识别 libc，会退回 `process.report.getReport()` 判断 musl/glibc。该报告枚举 CPU/网络，真机上阻塞 Node 事件循环约 32 秒，连带把 `/api/session/create` 和 account 请求拖到同一时刻返回。`harmony/runtime-preload.cjs` 通过 `NODE_OPTIONS` 预加载，只对**无参** `getReport()` 返回最小报告（`header` 为空即按 musl），带 options 的调用仍走 Node 原实现；`DSH_LITE_REPORT=0` 可关闭。真机 CPU profile 确认该调用从 32 秒降到毫秒级，冷启动到可用从约 50–55 秒降到约 11–15 秒。
- **fetch**：鸿蒙上 Node 以 `--jitless` 运行，V8 不暴露 WebAssembly，undici 的 fetch 不可用。运行时把纯 JS 的 `harmony/fetch-polyfill.cjs` 通过 `NODE_OPTIONS=--require` 预加载到宿主和终端里的 node，覆盖 JSON、SSE、重定向、压缩、AbortSignal、FormData/Blob 等语义；它还在 `Module._load` 返回 CJS 导出之前把 `undici.fetch` 换成补丁实现，因为 `dsh-web-fetch-http` 用 `await import("undici")` 绕开了全局 `fetch`（undici 解析响应依赖 WASM，`--jitless` 下必然失败）。
- **文档资源地址**：ArkWeb 把 `dsh-resource://file/…` 当 opaque URL，`new URL(...).hostname` 恒为空；官方 `@deepseek-ai/dsh-client-resources` 的 `protocolOf()` 用 `hostname` 当协议键，于是所有文件预览都被判成「没有 provider」，侧栏文件、聊天文件链接、交付物统一显示「文件资源服务不可用」。`Index.ets` 在文档起点注入 `RESOURCE_URL_DOCUMENT_SCRIPT`：只对 `dsh-resource:` 且原生 hostname 为空的 URL 补出 host，其它 scheme 与解析正常的引擎不受影响（回归测试 `tests/resource-url-shim.cjs`）。
- **附件上传**：`dsh-client-file-upload` 默认用 blob URL 建 Worker 上传，ArkWeb 上不可靠。`Index.ets` 通过 `javaScriptOnDocumentStart` 注入 `globalThis.__DSH_FILE_UPLOAD__ = { fetch }`，客户端启动时优先使用，把上传退回主线程同源 `fetch`；Blob 请求体被拒时退成 ArrayBuffer 重试一次。
- **图片附件**：随包引擎没有 sharp 原生模块，`--jitless` 也没有 WASM 兜底。`scripts/pack-native.sh` 在解包后的引擎树上给 `@deepseek-ai/dsh-attachment-local/lib/index.js` 追加 `scripts/engine-patch/attachment-pure-js.epilogue.js`：`probeImage`/`detectImage` 改成 PNG/JPEG/WebP/GIF 文件头解析，`normalizeImage`/`createRequestImage` 原字节透传；并把 `ensureDurableDirectory` 改成在沙箱边界的 `EACCES`/`EPERM` 停止向上 fsync（`/data/storage/el2` 不可读）。补丁按函数名覆盖，升级引擎时名字不匹配会直接让打包失败。
- **TLS**：启动时把 `certs/cacert.pem`（Mozilla 根证书）与可选的 `rawfile/harmony/extra-ca.pem` 合并成 `certs/bundle.pem`，`SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` 指向它；不做任何运行时放宽。附加 CA 不随仓库分发，仅供会拦截 HTTPS 的开发环境使用。
- **外链与新窗口**：账号页的「查询用量 / 充值 / 账号信息」都是 `<a target="_blank">`。ArkWeb 在 `multiWindowAccess(false)` 下拿不到新窗口处理器会把渲染进程挂住，表现就是点一下整页白屏、返回也退不出去（轮询停了，`webDialog`/`webMenu` 还停在 true，`onBackPress` 一直发 Escape）。`Index` 在文档起点注入的桥脚本里用捕获阶段拦下所有 `target=_blank`：站外的交给系统浏览器，站内的就地导航；另有 `onLoadIntercept` 兜底，主框架只允许留在本地 Web 服务。`onBackPress` 还会在页面状态超过 2.5 秒没采样时忽略残留浮层，并先把跑出站外的页面拉回本地，保证白屏时仍能退出。
- **下载**：官方 Web GUI 的「下载」是先把文件读成 `blob:` 再点一个 `<a download>` 锚点，ArkWeb 不会替页面保存 blob 下载（没设置下载委托时静默失败）。桥脚本在文档起点接管所有 `<a download>`（含脚本自己 `anchor.click()`、会话导出、预览下载）和 `onDownloadStart` 的 http(s) 下载：字节经 `javaScriptProxy`（`dshNative.put`）按 256 KB 分片交给 `Index`，壳层再弹系统保存框（`DocumentViewPicker`）写盘。**不要伪造 `window.dshDesktop`**：引擎里多处用 `"dshDesktop" in globalThis` 判断桌面版（onboarding、分析、拖拽等），塞假对象会改坏 Web 版行为。
- **缩放**：`Web` 组件设置 `zoomAccess(false)`，避免双指缩放破坏终端与侧栏的几何计算。
- **ripgrep 参数**：`librg.so` 由 IEC dlopen 进 shell 进程，`std::env::args()` 拿到的是宿主 argv（空），所以 `iec_rg_main` 必须用启动器传入的 `_argc/_argv` 重建命令行；否则引擎的代码搜索与 `grep` 工具会一直报 `ripgrep requires at least one pattern`。构建脚本已把 ripgrep 的 CLI 解析改走这份参数，见 `scripts/rg/build-ripgrep.sh`。
- **Go 命令（`gh`、`git-lfs`）**：stock Go 的 `c-shared` 用 initial-exec TLS，鸿蒙 musl 在 `dlopen` 时直接拒绝（`initial-exec TLS resolves to dynamic definition`，IEC 侧是退出码 125）。`GOOS=android` 也不行：它靠 bionic 的固定 TP 偏移/`pthread_key` 扫描找 goroutine 槽位，musl 的 `tsd` 是独立分配的。正确做法是 OpenHarmony 的 Go 工具链（`GOOS=openharmony`，c-shared 默认 TLSDESC）：先跑 `native/iec/scripts/optional/fetch_go_ohos.sh`，再设 `GO_TOOLCHAIN`；两个构建脚本都会检查产物不含 `R_AARCH64_TLS_TPREL64`。gh 固定在要求 go ≤ 1.26 的 tag（`GH_REF=v2.100.0`），并强制 `GOTOOLCHAIN=local`，否则 `go` 会自动下载官方新工具链、覆盖掉 openharmony 目标。

  **执行桥**：Go 的 `os/exec` 直接发 `execve`，IEC 的 shim 拦不到，而平台又拒绝执行任何 ELF，因此 `git-lfs` 在编译时打补丁（`native/iec/scripts/optional/gitlfs-ohos/`）：cgo 里 `fork()`，子进程只跑 C 代码并调用链接进来的 `exec/shim.c` 走 IEC 执行服务、成为替身；Go 侧照常 `waitpid`、读管道。`subprocess.Cmd`（git-lfs）与 `internal/run.PrepareCmd`（gh）对所有以 `$IEC_SYSROOT/bin/` 开头的命令（`git`、`ssh` 等）都走这条桥。
- **OpenSSL 配置**：`libcrypto` 的 `OPENSSLDIR` 编译为 `/etc/ssl`（绝不能再是构建机路径）。运行时的真实配置是随包的 `rawfile/harmony/openssl.cnf` → `<sysroot>/certs/openssl.cnf`，`OPENSSL_CONF` 指过去；`openssl req`/`ca` 找不到配置是致命错误，所以这一步不能省。
- **归档压缩后端**：`tar` 静态链入 bzip2/xz/zstd，`-j`/`-J`/`--zstd` 不再依赖设备上不存在的 `bzip2`/`xz` 命令。
- **node-pty**：`pty.node` 直接调 libc 的 `forkpty/openpty`，而 `/dev/ptmx` 在沙箱里打不开。构建脚本把 tty+exec shim 编进 `pty.node`，用 `--wrap` 把 `forkpty/openpty/posix_openpt/execvp`改到 IEC 的虚拟 PTY 与执行服务；真机上 `pty.spawn()` 已能启动子进程并回显。

## 扩展顺序

1. 真机验收 Web GUI 能加载、能连上引擎（`/api` 的 fetch 与 SSE 都通）。
2. 在 Web GUI 里发一条任务，确认工具调用落到 `__wrap_execvp` → IEC 执行服务。
3. 验证终端页与 PTY（`forkpty` 可用性、全屏程序）。
4. 验证工作区目录选择、文件上传、设置保存。
5. 之后再谈 Python、远程访问、MCP 与后台常驻执行。

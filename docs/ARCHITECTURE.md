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
4. 首次安装时把 `rawfile/tools/official-engine.tar.gz` 解到 `filesDir/runtime-<version>/engine`，把 `tools/npm.tar.gz` 解到运行时根，成功后写 `.installed` 标记；解包是同步阻塞调用，动手前先经 `onInstalling` 回调把「正在解包」交给界面并让出一帧，否则 300ms 轮询永远观察不到 `installing=true`，首次启动提示不会出现；
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

- 解包用的是 HAR 里的 `unpackResource()`：先把 rawfile 读进内存，再用 libarchive 的 write-disk 解到目标目录。`libarchive.so.13` 是运行期 `dlopen` 的共享库，必须随 HAP 打进 `libs/arm64-v8a/`。
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

- 输入：`engineVersion`、`nodeVersion`、按命令名排序的 `commands`、`official-engine.tar.gz`、`npm.tar.gz`、`entry/libs` 下所有 `*.so*` 的**内容**；
- 输出：`<engineVersion>-<sha256 前 12 位>`，写回 `entry/src/main/resources/rawfile/tools/runtime-manifest.json` 的 `version`；
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

`scripts/build.mjs` 默认在 hvigor 前执行 `sync`，`pack-native.sh` 也调用同一脚本，不再手算摘要；因此 `pack-native.sh` 现在要求构建机有 Node 18+。设备端 `ensure()` 读取 `.installed` 的内容并与当前 `manifest.version` 比较，内容不符时整棵重解，而不是只看标记是否存在。

注意：直接点 DevEco IDE 的 Build 不经过 `build.mjs`，不会自动 sync/check。发布流程应统一走命令行入口，或后续给 hvigor 增加预构建任务。

## 官方 Web 服务

- `--profile web` 首次运行会在 `$DSH_HOME/profiles/web/` 生成 `package.json`、`cordis.patch.yml` 和 `pnpm-workspace.yaml`，**不安装任何依赖**：bundle 从安装目录的 `node_modules` 解析。
- 引擎归档按 sdk profile 的插件表裁剪过，但包含了 web profile 需要的全部插件（`dsh-web-app`、`dsh-host-webserver`、`dsh-host-frontend-static`、`dsh-web-frontend` 与整套 `dsh-client-ui-*`）。`scripts/check-engine-web.sh` 用宿主 Node 跑 `--profile web --dump-config` 验证这一点：291 条插件、stderr 为空。
- 服务只绑 `127.0.0.1`，浏览器信任围栏接受回环地址；不要改成 `0.0.0.0`，那会把执行能力暴露到网络。

## 原生执行

IEC 的 `execStart` 拿到的不是普通 `fork`：鸿蒙应用进程不能直接 `fork/exec`，`.so` 由原生子进程装载，`.so` 里导出 `iec_bash_main` / `iec_node_main` 之类的 C 入口。命令行启动器是一个文本包装文件，记录目标 `.so`、入口符号和启动方式（本工程统一用 `2`，即鸿蒙原生子进程）。

`libnode.so` 重链接时用 `--wrap` 把 exec 家族换成了 IEC 的 RPC 版本（导出 64 个 `__wrap_*`），所以官方引擎里的 `child_process`（工具调用、终端、子代理）在设备上落到执行服务。`fork` 本身没有被拦截，是否允许由设备决定，`probeCaps().fork` 会先探测。

**Git**：`libgit.so` 用同一套 `--wrap` shim 接管文件与进程调用，静态链接 zlib/PCRE2；`libgit-remote-http.so` 额外静态链接 libcurl/OpenSSL，因此运行时只依赖 `libc.so`。`GIT_EXEC_PATH` 指到 `<sysroot>/bin`，`GIT_SSL_CAINFO` 指到合并后的 CA bundle，HTTPS 不做任何证书放宽。`git init` 不依赖模板目录，缺省模板警告可忽略。

**libc++ ABI**：随 HAP 打包的 `libc++_shared.so` 来自 DevEco SDK，只导出 `std::__n1` 命名空间的符号。所以所有 C++ 产物（`libnode.so`、`pty.node`、`require_builtin.node`）都必须用「libc++ 22 头文件 + `_LIBCPP_ABI_NAMESPACE __n1`」编译：V8 需要 libc++ 22 的 `<ranges>`，而 SDK 自带那套 `__n1` 头文件太旧、没有 ranges。用默认 `__1` 头文件编出来的 `.so` 在真机上 dlopen 会报 `_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`。

## 后台保活

鸿蒙会把切到后台的应用进程冻结，Web 界面背后的 dsh 引擎也跟着停，正在跑的 Agent 轮次就断在半路。做法照 HiSH：`platform/BackgroundKeepAlive.ets` 在界面加载完成后申请「模糊定位」，订阅 `locationChange`，再起一个 `BackgroundMode.LOCATION` 的连续任务（`backgroundTaskManager.startBackgroundRunning`）。这样应用在后台被当作前台服务对待，引擎和 WebSocket 都还活着。

需要三样东西，缺一不可：

- `module.json5` 的 `requestPermissions`：`ohos.permission.KEEP_BACKGROUND_RUNNING`、`ohos.permission.APPROXIMATELY_LOCATION`（带 reason/usedScene）、`ohos.permission.LOCATION_IN_BACKGROUND`；
- `abilities[].backgroundModes: ["location"]`；
- 用户授权模糊定位；被拒绝时保活直接跳过（`start()` 返回 false），不影响前台使用。

Windows 版的 DSH 退出时会停引擎；这里反过来——`aboutToDisappear` 才停 Web 服务与连续任务，切后台不停。

## 文件与安全边界

官方 Web GUI 直接暴露官方引擎的能力面：工作区选择、文件读写、终端、命令执行。安全边界因此只剩两条：

1. 服务只监听回环地址，界面只在本机 Web 组件里加载；
2. 应用沙箱和引擎自带的沙箱策略。引擎的策略（bwrap / Landlock）在鸿蒙上大概率不可用，探测失败会返回 `SANDBOX_UNAVAILABLE`。

真要把模型的能力收紧，得从引擎的 permission preset / 工具开关入手，而不是在界面层拦。

## 客户端插件与返回手势

两个客户端插件，职责分开：

- `@local/dsh-harmony-terminal`（`plugins/dsh-harmony-terminal`）：注册右侧栏终端 tab、上报 stage 矩形、`open/close/focus`，并从 `/api/session/list` 取当前会话的 `cwd` 下发，终端据此 `cd`。
- `@deepseek-ai/dsh-harmony-compat`（`plugins/harmony-compat`）：鸿蒙平台适配——用 `MutationObserver` 采样左抽屉（`aria-modal`）、设置对话框（`role=dialog`）、菜单（`role=menu`）、右栏（`收起右侧边栏` 是否可见），变化时立即用 `DSH_TERM:{op:'ui'}` 推给壳层；同时把选区「引用文本」浮层按 `offsetParent` 移到选区下方。

`Index.onBackPress()` 按浮层优先级消费返回：菜单 → 设置对话框 → 右侧栏/终端 → 左侧抽屉 → 系统。状态来自插件的 `ui` 推送，另有一个 500ms 轮询兜底，避免动画窗口期内误判。

## 运行时补丁

- **启动性能**：`node-addon-native-custom-loader` 在 OHOS 上无法从 ELF interpreter / `/proc/self/maps` 识别 libc，会退回 `process.report.getReport()` 判断 musl/glibc。该报告枚举 CPU/网络，真机上阻塞 Node 事件循环约 32 秒，连带把 `/api/session/create` 和 account 请求拖到同一时刻返回。`harmony/runtime-preload.cjs` 通过 `NODE_OPTIONS` 预加载，只对**无参** `getReport()` 返回最小报告（`header` 为空即按 musl），带 options 的调用仍走 Node 原实现；`DSH_LITE_REPORT=0` 可关闭。真机 CPU profile 确认该调用从 32 秒降到毫秒级，冷启动到可用从约 50–55 秒降到约 11–15 秒。
- **fetch**：鸿蒙上 Node 以 `--jitless` 运行，V8 不暴露 WebAssembly，undici 的 fetch 不可用。运行时把纯 JS 的 `harmony/fetch-polyfill.cjs` 通过 `NODE_OPTIONS=--require` 预加载到宿主和终端里的 node，覆盖 JSON、SSE、重定向、压缩、AbortSignal、FormData/Blob 等语义。
- **附件上传**：`dsh-client-file-upload` 默认用 blob URL 建 Worker 上传，ArkWeb 上不可靠。`Index.ets` 通过 `javaScriptOnDocumentStart` 注入 `globalThis.__DSH_FILE_UPLOAD__ = { fetch }`，客户端启动时优先使用，把上传退回主线程同源 `fetch`；Blob 请求体被拒时退成 ArrayBuffer 重试一次。
- **图片附件**：随包引擎没有 sharp 原生模块，`--jitless` 也没有 WASM 兜底。`scripts/pack-native.sh` 在解包后的引擎树上给 `@deepseek-ai/dsh-attachment-local/lib/index.js` 追加 `scripts/engine-patch/attachment-pure-js.epilogue.js`：`probeImage`/`detectImage` 改成 PNG/JPEG/WebP/GIF 文件头解析，`normalizeImage`/`createRequestImage` 原字节透传；并把 `ensureDurableDirectory` 改成在沙箱边界的 `EACCES`/`EPERM` 停止向上 fsync（`/data/storage/el2` 不可读）。补丁按函数名覆盖，升级引擎时名字不匹配会直接让打包失败。
- **TLS**：启动时把 `certs/cacert.pem`（Mozilla 根证书）与可选的 `rawfile/harmony/extra-ca.pem` 合并成 `certs/bundle.pem`，`SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` 指向它；不做任何运行时放宽。附加 CA 不随仓库分发，仅供会拦截 HTTPS 的开发环境使用。
- **缩放**：`Web` 组件设置 `zoomAccess(false)`，避免双指缩放破坏终端与侧栏的几何计算。

## 扩展顺序

1. 真机验收 Web GUI 能加载、能连上引擎（`/api` 的 fetch 与 SSE 都通）。
2. 在 Web GUI 里发一条任务，确认工具调用落到 `__wrap_execvp` → IEC 执行服务。
3. 验证终端页与 PTY（`forkpty` 可用性、全屏程序）。
4. 验证工作区目录选择、文件上传、设置保存。
5. 之后再谈 Python、远程访问、MCP 与后台常驻执行。

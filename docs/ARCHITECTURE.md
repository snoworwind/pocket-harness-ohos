# 架构与扩展

```text
ArkUI Index（只留一个 Web 组件 + 启动状态）
  └─ NativeRuntime
      ├─ IEC HAR（libiec_server.so）── execStart/execPoll/execWrite/unpackResource
      │     └─ 原生子进程：bash / node / toybox / tar / unzip / rg
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
4. 首次安装时把 `rawfile/tools/official-engine.tar.gz` 解到 `filesDir/runtime-<version>/engine`，把 `tools/npm.tar.gz` 解到运行时根，成功后写 `.installed` 标记；
5. 为每个命令写 `#IECSOv2` 启动器到 `runtime-<version>/bin`，toybox 的 applet 也逐个写；
6. 合并 CA bundle（Mozilla 根证书 + 可选附加 CA），构造环境变量；
7. 起 `node <engine>/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --port 0 --no-open`，从 stdout 里取出 `dsh web: <url>` 那一行；
8. 把这个 URL 交给 `Web` 组件。URL 带一次性 `?token=`，服务端用它换 cookie 后重定向到干净的 `./`。

端口用 `0` 让内核挑，避免和其他进程抢固定端口；`--no-open` 阻止引擎试图拉起系统浏览器。

## 进程与文件

```text
filesDir/runtime-<应用版本>-<内容摘要>/{bin,engine,certs,home,tmp}
filesDir/harness-home/          DSH_HOME：profile、会话 JSONL、设置、凭据都写在这里
```

- 运行时目录名带内容摘要：`sha256(应用版本 + 引擎版本 + Node 版本 + official-engine.tar.gz 全文 + npm.tar.gz 全文 + entry/libs 每个 .so 全文)` 的前 12 位。换了引擎、npm 或原生库就换目录、重新解包；只改 ArkTS 时摘要不变，升级后直接复用。`runtime-manifest.json` 的 `version` 字段就是这个值；手动替换引擎/原生库并希望强制重解时，直接改这个字段。
- `.installed` 标记只在引擎和 npm 都解包成功后写入；`ensure()` 成功后会删掉 `filesDir` 下其它 `runtime-*` 目录，避免每次升级多占约 450 MB。
- 目录被改坏时的恢复分三层：三项存在性探测失败 → 整棵重解；引擎启动报 `Cannot find module` / `failed to import` → 自动重解一次（`NativeRuntime.repair()`）；仍失败 → 界面提供「重新解包运行时」按钮。`repair()` 只删 `runtime-*`，不碰 `harness-home`。
- `harness-home` 永不被应用删除：覆盖升级保留会话与设置，卸载才清空。

- 解包用的是 HAR 里的 `unpackResource()`：先把 rawfile 读进内存，再用 libarchive 的 write-disk 解到目标目录。`libarchive.so.13` 是运行期 `dlopen` 的共享库，必须随 HAP 打进 `libs/arm64-v8a/`。
- 解包失败会留下半棵树，所以失败时清掉 `engine/` 再抛出；`fs.mkdirSync` 在目录已存在时会抛 `13900015 File exists`（即使 `recursion=true`），所以所有建目录都先 `accessSync` 判断。
- `.installed` 只在引擎和 npm 都解包成功后写入；升级引擎版本会换一个 `runtime-<version>` 目录，旧目录可以整删。

## 官方 Web 服务

- `--profile web` 首次运行会在 `$DSH_HOME/profiles/web/` 生成 `package.json`、`cordis.patch.yml` 和 `pnpm-workspace.yaml`，**不安装任何依赖**：bundle 从安装目录的 `node_modules` 解析。
- 引擎归档按 sdk profile 的插件表裁剪过，但包含了 web profile 需要的全部插件（`dsh-web-app`、`dsh-host-webserver`、`dsh-host-frontend-static`、`dsh-web-frontend` 与整套 `dsh-client-ui-*`）。`scripts/check-engine-web.sh` 用宿主 Node 跑 `--profile web --dump-config` 验证这一点：291 条插件、stderr 为空。
- 服务只绑 `127.0.0.1`，浏览器信任围栏接受回环地址；不要改成 `0.0.0.0`，那会把执行能力暴露到网络。

## 原生执行

IEC 的 `execStart` 拿到的不是普通 `fork`：鸿蒙应用进程不能直接 `fork/exec`，`.so` 由原生子进程装载，`.so` 里导出 `iec_bash_main` / `iec_node_main` 之类的 C 入口。命令行启动器是一个文本包装文件，记录目标 `.so`、入口符号和启动方式（本工程统一用 `2`，即鸿蒙原生子进程）。

`libnode.so` 重链接时用 `--wrap` 把 exec 家族换成了 IEC 的 RPC 版本（导出 64 个 `__wrap_*`），所以官方引擎里的 `child_process`（工具调用、终端、子代理）在设备上落到执行服务。`fork` 本身没有被拦截，是否允许由设备决定，`probeCaps().fork` 会先探测。

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

- **fetch**：鸿蒙上 Node 以 `--jitless` 运行，V8 不暴露 WebAssembly，undici 的 fetch 不可用。运行时把纯 JS 的 `harmony/fetch-polyfill.cjs` 通过 `NODE_OPTIONS=--require` 预加载到宿主和终端里的 node，覆盖 JSON、SSE、重定向、压缩、AbortSignal、FormData/Blob 等语义。
- **TLS**：启动时把 `certs/cacert.pem`（Mozilla 根证书）与可选的 `rawfile/harmony/extra-ca.pem` 合并成 `certs/bundle.pem`，`SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` 指向它；不做任何运行时放宽。附加 CA 不随仓库分发，仅供会拦截 HTTPS 的开发环境使用。
- **缩放**：`Web` 组件设置 `zoomAccess(false)`，避免双指缩放破坏终端与侧栏的几何计算。

## 扩展顺序

1. 真机验收 Web GUI 能加载、能连上引擎（`/api` 的 fetch 与 SSE 都通）。
2. 在 Web GUI 里发一条任务，确认工具调用落到 `__wrap_execvp` → IEC 执行服务。
3. 验证终端页与 PTY（`forkpty` 可用性、全屏程序）。
4. 验证工作区目录选择、文件上传、设置保存。
5. 之后再谈 Python、远程访问、MCP 与后台常驻执行。

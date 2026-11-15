# 侧栏终端改造记录（libvterm）

目标：照 `snoworwind/pocket-harness` 的做法，用 libvterm 原生终端替换坏掉的 Web 侧栏终端。

## 已落地

- `native/terminal/libvterm/`：从 pocket-harness 原样 vendored 的 libvterm（MIT，21 个文件）。
- `native/terminal/terminal_napi.cpp`：按 pocket-harness `terminal_jni.c` 的交付约定写的 NAPI 层：
  16 字节/cell（chars u32 / fg u32 / bg u32 / attrs u8 / width u8 / pad），
  颜色 `0xRRGGBB`，`0xFFFFFFFF` 表示默认色；提供 create/destroy/input/resize/
  copyScreen/scrollbackCount/copyScrollback/cursor。
- `native/iec/platform/ohos/har/src/main/cpp/CMakeLists.txt`：新增 `vterm` 静态库与
  `dsh_terminal` 共享库，随 HAP 打包为 `libs/x86_64/libdsh_terminal.so`。
- `entry/src/main/ets/pages/Terminal.ets`：ArkTS 终端页，Canvas 按 cell 绘制前景/背景/
  下划线/光标，支持回看滚动、按键条（Esc/Tab/Ctrl-C/Ctrl-D/方向键/回车），
  会话用 IEC `execStart` 起 `bin/bash -i`（stdin 保持打开，stdout/stderr 轮询后喂给 libvterm）。
- 入口：`Index.ets` 通过 ArkWeb `javaScriptProxy` 暴露 `window.harmonyTerminal.open()`，
  页面加载后注入一个顶部 `>_` 按钮调它。ArkUI 浮层会被 Web 表面吞掉触摸，所以按钮在页面里。

## 当前阻塞

- **bash 启动即崩（已定位，待端到端验证）**：`libbash.so` 的入口其实是
  `main(argc, argv, envp)` 的三参形状，但 `runtime-manifest.json` 里 bash/sh 没有声明，
  `NativeRuntime.ensure()` 一律按 `writeSoLauncher(..., 2)` 写成两参启动器。
  `SpawnSo` 因此只传两个参数，bash 的 `envp` 拿到寄存器里的垃圾值（实测 0x1），
  `initialize_shell_variables` 第一次解引用就 SIGSEGV（崩溃栈
  `initialize_shell_variables+177 → mov (%rax),%r12`，rax=1）。
  修复：manifest 给 bash/sh 加 `"arity": 3`，`ensure()` 按声明写启动器。
  这与架构无关，arm64 真机同样会崩。
- 终端页直接作为入口页时会先 `startIecServer()`，此时 caps 还没探测，会报
  `no launch route (fork=0, ncp=0)`；已在终端页启动顺序里补 `probeCaps()`。
- 终端页的 Canvas 在“直接作为入口页”的路径上偶发测到 0×0（onAreaChange 未触发），
  需要改成用窗口尺寸兜底。
- 宿主侧 Web 终端（DSH 官方 PTY）仍会因 `forkpty(3) failed` 抛未捕获 NAPI 异常并终止
  整个 node 宿主，表现为页面 “Failed to fetch / 重新连接中”。沙箱里 `/dev/ptmx` 对 shell
  也是 Permission denied。IEC 自带的 tty 伪造服务需要 `libiec_preload.so` 做符号拦截，
  但 musl 下 `dlopen(RTLD_GLOBAL)` 晚于 libc 加载无法覆盖 `forkpty`；实际试过：既不生效，
  还会让 bash 启动崩溃，已回滚。

## 侧栏接入（进行中）

- 终端不再是路由页，而是 `Index` 里的覆盖式 `TerminalView`（`@State showTerminal`）：
  之前用 `router.pushUrl` 打开，ArkUI 会在重启后把栈恢复出来，表现为“加载完成后黑屏”，
  改用浮层后 App 始终从 Index 启动。
- 页面加载后注入两件事：顶部 `>_` 按钮；以及捕获阶段的点击拦截——侧栏菜单里的
  “New terminal” 被截住后直接 `window.harmonyTerminal.open()` 打开原生浮层，
  不再创建宿主终端，也就绕开了 `forkpty` 崩溃。
- 已知问题：浮层里 Canvas 始终不绘制（黑底 + 按键条）。已验证不是尺寸问题
  （写死 360×720、改为始终构建 Canvas、去掉 `if (ready)` 条件、在 draw 里画边框和
  诊断文字都看不到），也不是 bash 问题（IEC 日志有 `bin/bash` spawn、无新 cppcrash）。
  下一步要确认 `CanvasRenderingContext2D` 的绘制表面是否真的绑定成功，或改用
  `XComponent` + 原生绘制。
- 仍未解决：
  - Canvas 不绘制（写死 360×720、始终构建、`onReady` 后重画都试过；下一步改用
    `XComponent` + 原生绘制，或确认 `CanvasRenderingContext2D` 的 surface 是否绑定）。
  - 打开浮层仍会造成 `APP_INPUT_BLOCK`（23:00 又产生一条 appfreeze），怀疑是
    `execStart`/`execPoll` 在 UI 线程上同步调用，需要把会话轮询挪到 worker/taskpool。

## 下一步

1. 画布不绘制：改用 `XComponent` + 原生绘制（或先用一个最小 Canvas 页验证
   `CanvasRenderingContext2D` 在本工程/本设备上是否可用）。
2. 打开浮层的 `APP_INPUT_BLOCK`：把 bash 会话的 25ms 轮询与绘制从 UI 线程挪走
   （taskpool/worker），并确认 `execStart` 本身是否阻塞。
3. 上述两点通过后，再补 `termViewOpen/Bounds/Visible/Output/Input/Close` 协议，
   把侧栏 tab 的占位区与原生视图联动；宿主层禁用 `terminal-bash` 作为兜底。

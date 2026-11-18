# 侧栏终端（libvterm）

终端是右侧栏里的一个可关闭 tab：tab 由 DSH 客户端插件注册，画面由 ArkTS 用 libvterm 原生绘制，PTY 走 IEC 的执行/终端服务。

## 分工

- `plugins/dsh-harmony-terminal/`
  - 注册 `terminal-harmony` 类型的右侧栏 tab（`keepMounted: true`，收起侧栏时保留视图与会话）；
  - 渲染一块透明 stage，把 `getBoundingClientRect()` 上报给壳层（`bounds` 消息）；
  - `open` / `focus` / `close` 消息，以及 × 关闭时停止会话；
  - 从 `/api/session/list` 读取当前会话的 `cwd`，通过 `cwd` 消息下发给终端（切换会话/工作区时重新对齐）。
- `entry/src/main/ets/pages/Terminal.ets`
  - `TerminalView` 绝对定位铺在 stage 矩形上，键盘弹出时压缩高度；
  - `libdsh_terminal.so`（libvterm 封装）负责屏幕单元与光标；
  - 用 IEC `execStart` 起 `bin/bash -i`（`pty: true`，保持 stdin），25ms 轮询输出，输入与窗口尺寸通过 `execWrite` / `execResize` 下发。
- `entry/src/main/ets/pages/Index.ets`
  - `onConsole` 解析 `DSH_TERM:<nonce>:` 桥消息（nonce 由文档起点脚本注入，每次启动
  随机生成，防止跨源页面伪造），维护 stage 矩形与浮层状态；
  - 返回手势：终端可见时先收起右侧栏，会话继续运行；只有 tab 的 × 才 `close` 并终止会话。

## 关键修复

- **bash 启动即 139**：`libbash.so` 的入口是 `main(argc, argv, envp)` 三参形状，而 `runtime-manifest.json` 里 bash/sh 没有声明 `arity`，启动器只传两个参数，`envp` 拿到寄存器垃圾值。给 bash/sh 补 `"arity": 3` 后修复。
- **命令库与执行核不匹配**：命令库内嵌的 tty/exec/fs shim 必须与 `libiec_server.so` 同源重建；终端 139 的另一半原因就是 arm64 命令库早于 PTY 相关提交，已按当前 `native/iec` 重编。
- **终端工作目录**：终端默认进入当前 DSH 会话的 `cwd`（而不是固定的 `files/home`），切换会话时同一 shell 内 `cd` 过去，不重建会话。
- **键盘**：Web 页面不处理软键盘，终端视图在 `keyboardHeightChange` 时把输入区抬到 IME 上方，横屏时压缩终端高度。
- **关闭语义**：收起侧栏只是隐藏视图，会话继续跑；tab 的 × 才发 `close` 并释放 PTY。

## 已知边界

- 仅支持 arm64 与 x86_64 两种 OHOS ABI；
- 全屏 TUI 应用（vim 等）依赖 libvterm 的能力与 PTY 尺寸，部分鼠标/剪贴板转义序列未实现；
- 终端会话不跨应用进程存活：应用被杀后会话结束；
- 输入法组合键、部分 Ctrl 组合在软键盘上不可用，需使用按键条。

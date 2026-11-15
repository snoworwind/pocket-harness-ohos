# 软键盘滑入闪白调查（2026-11-15）

## 目标现象

键盘尚未完全就位时，即将被键盘覆盖的区域短暂变白；键盘到位后的静态画面正常。

## 已验证的范围

- 仅连接 `127.0.0.1:5555` 鸿蒙 x86_64 模拟器，未在真机上操作。
- 原精简探针在系统深色模式下，用户手动确认没有闪白。
- 原探针未设置 `Web.darkMode`，CDP 实测 `prefers-color-scheme: dark` 为 false，尽管页面本身固定为深色。
- 探针补齐完整界面的 Web 访问设置、`darkMode(Auto)` 和 `forceDarkAccess(false)` 后，CDP 实测 dark 为 true。一次连续截图覆盖键盘滑入过程，未见白块。
- 通过 CDP 临时将 html 改为透明、body 保持深色（对应官方前端的背景层次），另一次连续截图覆盖滑入过程，未见白块。

这些是有限次、离散截图的对照结果，不能证明不存在更短或偶发的闪白，也不能证明完整应用已修复。

## 证据

- `.test-build/build-kb-compare-outside.log`：对照探针构建成功，已签名并安装。
- `.test-build/kb-auto/`、`.test-build/kb-auto-sheet.jpg`：自动深色配置，10 帧。
- `.test-build/kb-body2/`、`.test-build/kb-body2-sheet.jpg`：透明 html / 深色 body，10 帧。前两帧包含应用重新进入动画。
- `.test-build/kb-body/` 是误采的桌面画面，不作为键盘证据。
- `.test-build/inspect-web.cjs`：本机 ArkWeb CDP 诊断脚本，读取背景色、主题和视口。调试端口转发到 19222，应用重启后需重新发现 devtools socket PID。

## 尚未覆盖

完整 Index 页面每两秒读取网页背景，并同步原生窗口与组件；精简探针没有运行此轮询，也没有官方页面的应用结构、主题切换和输入编辑器。因此尚未排除布局重排、窗口/网页主题不一致或轮询更新与键盘动画重合。

完整应用的 Node、bash 等运行时仅提供 arm64 库，且 NativeRuntime 使用 arm64 库路径。模拟器的探针仅有 x86_64 的 IEC 支持库，不能把入口直接切回 Index 就视为有效的完整界面测试。尝试在 Windows 上运行随包归档也因缺少 Windows 原生绑定失败，未得到完整 GUI 的测试结果。

## 下一步判定方法

先让模拟器承载真实官方前端及相同的原生窗口同步逻辑，再采集过渡帧。将窗口、ArkUI 根容器和 Web 表面临时设置为不同标记色，以确定短暂露出的是哪一层。复现后再修改对应层，不以增加背景色调用或切换避让模式代替根因证据。

参考：

- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/web-set-dark-mode/
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/web-docking-softkeyboard/

## 2026-11-15 第二轮：在模拟器上跑起完整应用

### 完整界面此前起不来的真实原因

`entry/libs/x86_64` 补齐后，应用能解包引擎并启动 `dsh --profile web`，但前端报
`web boot: 31 entries did not activate`，全部在等 `sessions` 等服务。设备侧
`files/logs/web-stderr.log` 给出了宿主侧的根因：

```
dsh: warning: 11 entries did not activate
session-controller (@deepseek-ai/dsh-api-session-controller): failed to import:
  RangeError: The number NaN cannot be converted to BigInt because it is not an integer
    at JSBI.BigInt (.../jsbi/dist/jsbi-cjs.js)
    at file://.../@js-temporal/polyfill/dist/index.esm.js:1:56846
```

`@js-temporal/polyfill` 在模块初始化时执行 `e.BigInt(Date.now()%1e6)`，在这个自建的
x86_64 libnode（v24.22.1 / V8 13.6.233.17-node.58）上得到 `NaN`。`session-controller`
宿主插件导入失败后，它的浏览器侧条目不会进入 `window.__DSH_BOOT__`，前端因此缺少
`sessions` 服务，31 个条目连锁挂起。同一份引擎在 WSL x86_64 Node 22 上运行正常，
说明问题在自建 libnode，而不是归档本身。

模拟器内用 `execStart` 直接跑 node 探针（避免经 bash 传参）测得：

```
clock 1794745238053
mods  NaN 491892 1 ...
```

即 `1794744491892 % 1000000` 为 `NaN`，而 `% 1e6`、`% 1000`、`% 10` 正常。取模缺陷
与主题、Web 深色模式、键盘都无关，但会挡住完整界面的启动。

### 临时绕过

把归档里 `@js-temporal/polyfill/dist/index.esm.js` 的

```
let t=e.BigInt(Date.now()%1e6);
```

改成 `let t=e.BigInt(0);`。`t` 只是时钟的初始亚毫秒余量，置 0 语义上无影响。用
`tar -xzf` 解包 `rawfile/tools/official-engine.tar.gz`、改文件、`tar -czf` 重打包
（条目数前后都是 30267）。原始归档备份在 `.test-build/official-engine.orig.tar.gz`，
补丁版在 `.test-build/official-engine-patched.tar.gz`。

这是针对模拟器 x86_64 运行时的绕过，**不是**对取模缺陷的修复；真正的修复在 libnode
的 V8 构建侧。真机 arm64 构建是否同样受影响尚未验证。

### 完整界面验证结果

绕过之后完整 Web GUI 正常启动：预览声明、Get started、工作区选择、输入框与键盘都能
使用。在深色主题下做了 3 轮“收起键盘 → 点击输入框 → 连续截图”：

- 每轮 16 帧，覆盖键盘滑入全过程（第 2–4 帧为动画中间态）。
- 键盘上方区域（画面 40%–55%）平均亮度 37.7 → 31.6，没有白色跳变。
- 纯白像素比例只在键盘出现后从 0.13% 升到 0.99%，来自键盘自身的白色按键。

也就是说，**这个模拟器 + 当前构建 + 深色主题下没有复现白块**。之前真机上的白块还
需要在同一构建上复测；真机当时安装的包早于当前的窗口背景同步逻辑。

### 另一个待查问题

`bash -lc 'node --version'` 在设备上以 139（SIGSEGV）退出，而由 `execStart` 直接启动
`bin/node` 正常。可能是启动器在 bash 内被再次 exec 时的加载路径问题，会影响终端/工具
执行，需要单独定位。

## 2026-11-15 第三轮：白块根因与修复

### 复现

设备内单张 `snapshot_display` 约 160ms，之前 10 帧一组根本盖不住白块。改成 8 个
`snapshot_display` 并行（约 35ms/帧，~28fps）后，在完整界面的键盘滑入过程中抓到了
2 帧：画面 61.6% 以下整块纯白，上一帧还是正常深色，下一帧变成键盘的深灰底。

### 定层

把三层背景临时改成品红（窗口）、蓝色（Web/根容器）后重抓，白块变成了**蓝色**——
说明露出的是应用自己的背景层，不是输入法窗口。

### 真正的根因（两处叠加）

1. **桥接返回值被解码了两次。** `syncBarsFromPage()` 用 `controller.runJavaScript`
   取主题，ArkWeb 把这个 JSON 字符串结果又编码了一层（外层带引号）。代码只
   `JSON.parse` 一次，得到的是字符串而不是对象，`parsed.dark` 恒为 `undefined`、
   `parsed.bg` 恒为 `''`，于是每次都按浅色处理。设备上用标题诊断确认修复前是
   `DSHBG:#00FF00:#F7F7F0`（传入的就是浅色回退值 `#F7F7F0`）。
2. **颜色格式不被 ArkUI 接受。** 页面的 `getComputedStyle(body).backgroundColor`
   是 `rgb(21, 21, 23)`；`Web.backgroundColor()`、根容器 `.backgroundColor()` 和
   `window.setWindowBackgroundColor()` 只认 `#RRGGBB`/`#AARRGGBB`。即使桥接修好，
   把 `rgb(...)` 直接传下去仍是非法值，底层照样回落白色。

平时页面自己画满深色，看不出问题；键盘避让重排的瞬间 Web 表面被裁短，露出的正是
这层浅色/白色。这也解释了为什么改 `WebDarkMode`、`html`/`body` 背景、
`forceDarkAccess` 都没有效果。

### 修复

- `syncBarsFromPage()`：结果以 `"` 开头时再解一层，兼容双层编码。
- `Index.normalizeColor()`：把 `rgb(r, g, b)` / `rgba(...)` 统一转成 `#RRGGBB`，
  非法值回退到深/浅默认色。
- `applyBars()` 只使用规范化后的颜色写 `barBg` 和窗口背景。
- 启动完成后主动同步一次并挂上 2 秒轮询，不再只依赖 `onPageEnd`。
- `followSystemBars()` 先用 `context.config.colorMode` 定初始色；`mediaquery` 的
  `matches` 在这台设备上不可靠，只保留它的 `change` 事件。

### 验证

- 设备内标题诊断：修复前 `DSHBG:#00FF00:#F7F7F0`，修复后
  `DSHBG:#151517:rgb(21, 21, 23)`，与页面实际背景一致。
- 用户手动连续点击输入框确认：白块消失。

抓帧方法留档：设备内单张 `snapshot_display` 约 160ms，8 个并行可到 ~35ms/帧
（~28fps），白块只有 1–2 帧宽，必须用并行抓帧才看得到。




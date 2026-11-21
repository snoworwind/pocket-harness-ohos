# 验证说明

记录截至 2026-11-21 的验证范围。凡是没在真机上跑过的条目都明确标为「未验收」，不写成已通过。测试设备为一台 HarmonyOS 6.1（API 26）手机与 x86_64 模拟器。

## 2026-11-21 GitHub issue 修复（#2–#6、终端回车）

本轮处理仓库里 5 个 open issue，并另外修了终端回车后软键盘自动收起、以及插件启用状态在应用更新后被关闭的问题。
环境：Windows 构建机 + DevEco Studio（hvigor），WSL 里有原生库与官方引擎暂存树。
先在 arm64 上构建；随后按用户要求补齐 x86_64 运行时，并在 HarmonyOS 6.1.1（API 24）模拟器上做了验收（见下方 x86 小节）。

| Issue | 修复 | 本轮验证 |
| --- | --- | --- |
| #2 fetch polyfill 收到 HTTP 205 抛未捕获异常 | `makeResponse()` 改用 `isNullBodyStatus()`：HEAD/204/**205**/304 都摘掉 body 并 `resume()` 底层连接；Response 构造放进 `settleWithResponse()`，状态码/响应头非法时 reject Promise 而不是在异步 HTTP 回调里 throw | `node scripts/test-fetch-polyfill.cjs` 19 项 PASS（新增 205 空 body、非 2xx–5xx 状态码 reject、无 body 判定）；`node tests/fetch-redirect.cjs` 12 项 PASS；设备端未单独构造 205 |
| #3 插件隔离/恢复失败会丢配置与恢复记录 | `quarantine()` 先保存**完整原 bundle 列表**再改配置；隔离记录改为可追加的 `records`（兼容旧单条格式）；配置与记录都改成临时文件 + rename；写失败时回滚配置和已移动的包；一个包都没移动成功时不改配置。`restoreLastQuarantine()` 只在**所有包都移回且配置写成功**后删记录，否则保留记录并返回错误文案；`Index` 把错误显示在启动页 | `node scripts/test.cjs` 57 项（56 pass / 1 skip，含 plugin-guard 5 项）；ArkTS 经 hvigor `CompileArkTS` 通过；失败路径未在设备上构造 |
| #4 多终端标签共用原生终端状态 | 壳层只有一路原生终端，插件改为 `multiple: false`（内核单实例地址），所有桥消息用固定 `OWNER`；`Index` 记录 owner 并忽略不匹配的 bounds/visible/focus/close，关一个标签不再清掉共用状态；`watchActiveSession` 的 cwd 也统一 owner | ArkTS 编译通过；**x86 模拟器实测**：连续两次「原生终端」仍只有 1 个 tab / 1 个 stage，bash 可执行 `echo hello` |
| #5 后台保活异步启停竞态 | `BackgroundKeepAlive` 改成串行队列 + generation：start/stop 按顺序执行，等待点后代号变化就回滚；本次新建的定位订阅在失败/被取代时撤销；连续任务刚启动就被取代时立即 `stopBackgroundRunning`；stop 失败保留 `active` 供下次重试 | ArkTS 编译通过；代码审查覆盖权限拒绝、等待中 stop、启动后立即 stop 三条路径；竞态未在设备上复现 |
| #6 全屏且无状态栏开关、挖孔挡内容、启动页简陋 | `harmony-compat` 新增 `showSystemBars`（volatile）设置行；`NativeRuntime.readShowSystemBars()` + `Index.applySystemBars()` 每 3 秒跟随，`EntryAbility` 启动时先按镜像值决定布局；沉浸式时按 `TYPE_SYSTEM`/`TYPE_CUTOUT`/`TYPE_NAVIGATION_INDICATOR` 给 Web 上下留出避让区（终端浮层同步偏移），系统栏可见时恢复安全区布局；启动页加应用图标、副标题和更清楚的解包提示 | ArkTS 编译通过；`official-engine.tar.gz` 重新打包（含新插件），运行时清单 `0.2.2-rc.1-74c426762080`；**x86 模拟器实测**：设置页两行文案与开关都在，切换后系统栏即时出现/消失，沉浸式下挖孔区域留白 |
| 终端回车后软键盘收起 | `TextInput` 改用 `enterKeyType(EnterKeyType.Send)`，`onSubmit` 里发送换行、清空输入并重新请求焦点（下一帧再补一次），可以连续敲命令 | ArkTS 编译通过；**x86 模拟器实测**：软键盘动作键显示「发送」，`echo hello` 执行后输入框清空、键盘保持展开 |
| 插件启用状态在更新后被关闭 | `NativeRuntime` 把 auto-review 改为三态：显式 `true` 注册、显式 `false` 移除、没有显式值时**不改动已有行**；旧版本默认写入的行按「用户此前在用」沿用，并把 `autoReview: true` 固化进 `harmony-native.json`；其它壳层托管的插件行同样只补缺、不删用户状态 | ArkTS 编译通过；代码审查覆盖 true / false / 缺失三条分支；旧 profile 升级场景未在设备上构造 |

### x86_64 模拟器验收（2026-11-21）

模拟器：HarmonyOS 6.1.1（API 24），`hdc -t 127.0.0.1:5555`。x86 运行时使用
`/var/tmp/deepseek-harmony-x86` 里的 9 个命令库（node/bash/toybox/tar/cpio/unzip/zip/rg）
重新打包引擎（x86 addons + 新插件），HAR 以 `abiFilters: ["x86_64"]` 构建，HAP 仅含 x86 库。

- 首次启动解包：引擎 49 MB 约 23 s，npm/python/vim 约 7 s；`IEC_LOGGER` 无
  `THREAD_BLOCK`/`APP_FREEZE`。
- 发现并修复：当前预编译 x86 `libnode.so` 进程内**第一次浮点取模返回 NaN**，撞上
  `@js-temporal/polyfill` 初始化，导致 11 个核心插件 import 失败、界面停在
  「Failed to load plugins」。`runtime-preload.cjs` 在 x64 上先用变量做一次浮点取模
  预热（字面量会被解析期折叠），修复后 `web-stderr.log` 无插件失败，Web GUI 正常。
- 已验证：
  - Web GUI 正常显示工作区选择、会话输入框与「Get started」；
  - 设置 → General 末尾出现 `HarmonyOS adaptation / Background keep-alive` 与
    `Show system status and navigation bars` 两行；
  - 打开系统栏开关后状态栏（时间/电量）与底部手势条立即出现，
    `harmony-native.json` 变为 `{"keepAlive":false,"showSystemBars":true}`；关掉后恢复
    沉浸式，顶部保留挖孔高度的背景留白（[截图](images/x86-system-bars.jpg)）；
  - 原生终端：打开后有 `bash-5.3$` 提示符，`echo hello` 正常执行；软键盘动作键为
    「发送」，执行后输入框清空、键盘不收起（[截图](images/x86-terminal-enter.jpg)）；
    再次点「原生终端」仍只有一个 tab；
  - 终端插件标志 `window.__dshHarmonyTerminalReady/Apply === true`，nonce 已注入；
  - 首页/工作区选择界面见 [截图](images/x86-home.jpg)。
- 未验证：x86 运行时只有 12 个命令，python/git/gh/curl 等未构建，未测试这些功能；
  auto-review 旧 profile 升级保持、保活竞态、插件隔离失败路径仍未在设备上构造。

### 0.1.0.6 首次启动看门狗与安全模式误隔离（2026-11-21）

0.1.0.6 首次安装到真机后的第一次启动在解包末尾触发 `THREAD_BLOCK_6S` / `APP_FREEZE`；
第二次启动进入安全模式，把所有第三方插件（包括用户启用的 auto-review）移进隔离目录。

- **根因**：`NativeRuntime.pruneOldRuntimes()` 在 `ensure()` 里**同步递归删除**旧
  `runtime-*` 目录（约 593 MB、2.6 万个文件），跑在 UI 线程上；解包完成后一次删完，
  超过 6 秒看门狗阈值。进程被杀时还没走到 `markBootSucceeded()`，`.boot-in-progress`
  残留，下次启动被误判为「插件导致启动失败」，于是整批隔离。
- **修复**：
  1. 旧运行时改为**分片删除**：每个宏任务最多 8 ms，剩余交给 16 ms 定时器继续；
     目录用不可见后缀标记二次访问，非空/失败不再重试，避免空转。
  2. `PluginGuard` 新增一次性自动恢复：只对「上次启动未完成」这类崩溃/看门狗隔离
     生效，每个安装最多尝试一次（`.auto-restore-attempted`）；插件 import 失败导致的
     隔离不自动恢复，避免反复把引擎弄挂。
  3. Web GUI 起来后若仍有隔离，显示「安全模式：已停用 N 个插件 / 恢复插件」提示条。
  4. 新增宿主测试 `tests/plugin-guard.cjs`（5 项：原配置保存、完整恢复、缺目录不改配置、
     半恢复保留记录、自动恢复仅一次/插件失败不自动恢复），并纳入 `scripts/test.cjs`。
- **验证**：
  - 修复后的 0.1.0.6 已装到真机（versionCode 7）并启动：`hilog -x` 中
    `THREAD_BLOCK` 与 `APP_FREEZE` 计数均为 0；Web GUI 与插件页正常，
    `web-stderr.log` 无 `did not activate`。
  - `node tests/plugin-guard.cjs` 5/5 通过；`node scripts/test.cjs` 纳入后通过。
  - **未在设备上复现**「全新解包后删除旧运行时」这条路径：修复包安装时 runtime 已存在，
    没有旧目录可删；分片删除的实际耗时留待下一次运行时升级复核。
  - **自动恢复未在设备上触发**：手机上的隔离由旧版本造成，用户已手动恢复；当前自动
    恢复逻辑只有宿主测试覆盖。下次再出现崩溃类隔离时会走一次性自动恢复。

### 本轮未验收（明确不写成已通过）

- **arm64 真机**已安装 0.1.0.6（versionCode 7）并启动成功，但界面/终端功能项仍以 x86
  模拟器验收为准；分片删除旧运行时与自动恢复插件这两条路径没有在真机上触发；
- 挖孔/手势条避让的像素值与真机 `getWindowAvoidArea()` 返回值是否一致未验证（模拟器只看到留白）；
- 系统栏可见时状态栏/导航栏底色在报告机型上是否仍被系统强制成白色（历史问题）未复测；
- `showSystemBars` 切换时 ArkUI 安全区布局重排是否闪动未逐帧验证；
- 终端 `EnterKeyType.Send` 在不同输入法下的行为未逐一验证（模拟器键盘为「发送」且保持展开）；
- 插件隔离/恢复的失败路径（目录只读、磁盘满）未在设备上构造复现；
- auto-review 从「旧版本自动安装」升级到本版的迁移未构造旧 profile 复现。


## 2026-11-18 安全审查整改

针对 `SECURITY-REVIEW-2026-11-18.md` 的整改。本轮**没有连接设备、没有交叉编译原生库、没有重打包 HAP/引擎归档**；宿主侧验证项与真机未验收项严格分开。

| 报告项 | 修复 | 本轮验证 |
| --- | --- | --- |
| H-01 生产包开启 WebView 调试 | `EntryAbility` 改用 `BuildProfile.DEBUG`：debug 开、release 显式关；删除 `pages/KbTest`、`kbtest.html` 与 `main_pages.json` 注册 | 本机 hvigor 生成的 `BuildProfile.ets` 有 `DEBUG` 字段，SDK `@ohos.web.webview.d.ts` 有 `setWebDebuggingAccess(boolean)`；release 产物的 `DEBUG=false` 未构建验证 |
| H-02 定位权限用于保活 | **按用户决定保持现状，未改**；接受风险写入 [SECURITY.md](SECURITY.md) 与 README | — |
| M-01 WebView 跨源桥/注入/console | `javaScriptProxy.permission` 限定 `http://127.0.0.1:<port>`；`scriptRules` 只给本地 origin；终端/下载桥加每次启动随机 nonce（终端插件与 rawfile 副本同步）；console 校验 `getSourceId()` 来源；下载分片限 256 KiB、单任务 256 MiB、8 个任务、5 分钟超时；`fileAccess`/`databaseAccess` 关闭；主框架导航按 `url.URL.origin` 收口 | `node scripts/test.cjs` 桥脚本顺序测试通过；nonce/配额逻辑在 Node 侧做过临时验证（未入库）；ArkWeb 的 permission/scriptRules/getSourceId 真机行为未验证 |
| M-02 fetch 跨源重定向泄漏认证头 + HTTPS→HTTP 降级 | 跨 origin 剥离 `authorization`/`proxy-authorization`/`cookie`/`cookie2`/`host`；303 与 301/302 POST→GET 清理请求体头；拒绝 HTTPS→HTTP 与非 http(s) 目标 | `node scripts/test-fetch-polyfill.cjs` 16 项通过；新增 `node tests/fetch-redirect.cjs` 12 项通过（含自签证书端到端降级用例） |
| M-03 上游/二进制缺校验 | `lib/common.sh` 新增 `iec_fetch_verified`（curl + SHA-256，失败即退）与按 commit 的 clone 校验；所有上游依赖已固定 SHA-256 或 commit（依据见 `docs/SOURCES.md`）；`pack-native.sh` 缺新 npm/引擎产物时失败，归档生成 `ENGINE-MANIFEST.sha256`/`official-engine.sha256`；`runtime-manifest.mjs` 校验 sidecar | 所有改动的 shell 脚本 `bash -n` 通过；`runtime-manifest check` 通过；15 个上游 tarball 已按官方地址实测计算 SHA-256（zstd 另有官方 `.sha256` 对得上）；npm/引擎归档已重建 |
| M-04 原生二进制加固不足 | `native/iec/CMakeLists.txt` 按编译器能力启用 `-fstack-protector-strong`、`-D_FORTIFY_SOURCE=2`、PIE、RELRO/now；`build_git.sh`/`build_curl.sh` 默认打开 FORTIFY，仅 `IEC_NO_FORTIFY=1` 显式降级；审计脚本检查 ELF 加固标志 | 宿主 CMake Release 构建确认 `Type: DYN`、`BIND_NOW`、`__stack_chk_fail`、FORTIFY 宏；OHOS HAR 已用 DevEco NDK 重建，HAP 内 `libiec_server.so` 确认 `__n1` ABI、`BIND_NOW`、`__stack_chk_fail` |
| M-05 运行时完整性只靠目录名 | `.installed` 改为 JSON schema 2：版本 + 6 个关键文件 SHA-256 + 随包清单摘要；启动时重算抽查，不符/旧格式整棵重解，不删 `harness-home`；安装标记改到最后一步写 | `node scripts/runtime-manifest.mjs check` 通过；Node 侧语法转译通过；真机启动耗时与哈希 API 行为未验证 |
| M-06 日志含 token/argv/env 且无轮转 | 壳层 `appendLog`/`writeLog` 落盘前脱敏，`dsh.log`/`web-stderr.log` 4 MiB 轮转保留 2 份；原生 `Logger::Redact` 统一脱敏所有 sink，文件 sink 4 MiB 轮转；启动时清理旧的 `iec-*.log`（保留最近 10 个）；exec_server 完整 argv/env 降到 Debug（`IEC_LOG_DEBUG=1`） | 脱敏纯函数 10 组样例通过（临时脚本，未入库）；原生轮转/脱敏手写 7 MiB 验证；`node scripts/test.cjs` 通过 |
| M-07 原生边界 DoS/完整性 | py_runner：输出 64 MiB 上限、并发 16、env/arg 256、单字符串 64 KiB、内联 stdin 16 MiB、文件 stdin 流式且 64 MiB 上限、读空闲 30s/写 60s 超时；归档硬链接/符号链接越界 fail-closed + `SECURE_SYMLINKS`/`SECURE_NOABSOLUTEPATHS`；`exec_so` 改单次 `open(O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)` + `fstat`；fork 前构造环境、去掉子进程 `setenv`；延迟 kill 校验 `starttime`；TTY 归属校验；procmap 5 分钟 TTL + 1024 上限；`SO_PEERCRED` 不可用改拒绝 | WSL 宿主回归 `bash native/iec/scripts/test_iec_native_host.sh`：80 checks 通过、fs shim 15 checks（1 项既有 SKIP）；`native/iec/tests/py_runner/run.sh` 19 项通过；CMake 构建 iec_server 通过 |
| L-01 终端 cwd 换行注入 | `Terminal.writeCd()` 拒绝含 `\n`/`\r`/`\0` 的 cwd，保留单引号转义 | Node 侧对照验证通过；真机未验收 |
| L-02 URL 过滤偏宽/能力面 | 改用 `url.URL` 解析比较 origin；主框架只允许本地 http(s)；`data:`/`blob:`/`javascript:`/`file:` 拦截；关闭 `fileAccess`/`databaseAccess` | 未真机验证；`about:blank` 拦截是否影响首屏需真机确认 |
| L-03 默认注册实验性 auto-review | 默认不注册；仅 `harmony-native.json` 里 `autoReview: true` 时注入，关闭时清掉旧插入行；`harmony-compat` 镜像文件改为合并写，保留其它字段 | 未真机验证 |
| L-04 插件无沙箱 | 在 README 与 `docs/SECURITY.md` 明确“安装插件 = 完全信任”，不再把 `PluginGuard` 描述为隔离 | 文档 |
| L-05 CI/发布门禁不完整 | 新增 `host-tests.yml`、`runtime-manifest.yml`、`binary-audit.yml`；action 固定 commit SHA；`build.mjs` 增加 `--release`，release 默认强制严格清单校验；`secret-scan.yml` 增加历史扫描 | 4 个 workflow YAML 解析通过；GitHub Actions 未实际运行 |
| L-06 secret-scan 覆盖不足 | 增加华为 AK/SK、`sk-proj-`、PEM 私钥、GitLab/阿里云/腾讯云/Stripe/npm/HuggingFace/SendGrid/Google OAuth 规则；pre-push 扫推送范围内所有提交；新增 `--history` 与提交信息扫描；对历史中已移除的公开 CA 与无口令构建模板按精确 blob SHA-256 豁免 | `node --test tests/secret-scan.cjs` 7/7 通过；`--all` 与 `--history`（默认 200 提交）本机通过 |
| L-07 调试页进入 release | 已删除 `KbTest.ets`、`kbtest.html`、页面注册 | 全仓无残留引用；HAP 未重建 |
| L-08 导出 Ability 与外部入口 | 未改：`EntryAbility` 仍 `exported: true`（桌面启动器需要），当前无外部 want 参数处理；边界写入 SECURITY.md | — |
| L-09 原生进程生命周期 | 与 M-07 合并处理：`SO_PEERCRED` 不可用拒绝、延迟 kill 身份校验、procmap 清理、TTY 归属 | 宿主回归覆盖 TTY 归属与 pid 身份判据 |

### 本轮未验收（明确不写成已通过）

- release 构建实际产物里 `BuildProfile.DEBUG=false`、DevTools 无法附着；
- ArkWeb 的 `javaScriptProxy.permission`、`scriptRules` 精确 origin（含端口）、`ConsoleMessage.getSourceId()`、`fileAccess(false)` 在 API 18 真机上的行为；
- nonce 桥端到端（终端 tab、下载保存、外链跳转）与同源预览仍可读 nonce 的残余风险；
- 运行时 `.installed` 哈希校验的真机耗时、`hash.hash` 行为与旧版升级首启重解；
- 壳层/原生日志脱敏与轮转在设备上的实际效果；
- 真机只验证了覆盖安装、运行时重解包与 Web GUI 首屏；nonce 桥（终端 tab/下载/外链）、日志轮转、TTY 归属、py_runner 上限、`autoReview` 开关等仍未逐项验收；
- 本轮只重建了 IEC 服务端库（`libiec_server.so`、`libncploader.so`、`libdsh_terminal.so`）与 npm 归档；`libnode`、`libpython`、`git`、`gh` 等命令库沿用上一轮产物，其 `CANARY=no` 仍待单独重编；
- 4 个 GitHub Actions workflow 未实际运行；发布页尚未真正发布，只有本地 `dist/SHA256SUMS` 自校验；

### 交叉编译与重打包（2026-11-18）

| 项目 | 操作 / 结果 |
| --- | --- |
| OHOS 交叉编译 | WSL SDK 的 libc++ 命名空间是 `__h`，与设备随包 `libc++_shared.so` 的 `__n1` 不一致，直接链接报 `std::__h::basic_string` 未定义；改用 DevEco NDK（`__n1`）经 hvigor 重建 HAR，WSL 只负责 npm/引擎归档 |
| `libiec_server.so` | `node scripts/build.mjs --clean`：HAR 重编，未 strip 4,721,016 B；HAP 内 strip 后 1,012,864 B，SHA-256 `7b7bdc48f273482c3e20ab5fffb36d1445b2378ba8a497905de0f944ac83a8ab`；确认 `__n1` ABI、`BIND_NOW`、`__stack_chk_fail`，且包含本轮新增的 “unsafe symlink”“caller identity is unavailable”“output limit” 等路径 |
| `npm.tar.gz` | `build_node.sh npm` 从 Node v24.22.1 `deps/npm` 重打，2,788,831 B，SHA-256 `c051c4e26fa673550db6b2fe8267923847cc9a47bd9b7727eb2a2bf2f66e7df1` |
| `official-engine.tar.gz` | 重打包（含 harmony-compat nonce、`ENGINE-MANIFEST.sha256` 26,685 个文件、package-lock），49,355,576 B，SHA-256 `f070799c2a506c69f63d09453936ede46408be48760fbcca4c637e503d80a970`；sidecar 自校验通过 |
| 运行时清单 | `0.2.2-rc.1-26cc87b18562`；Windows 与 WSL 两个 Node 环境算出的版本一致（修复了 `localeCompare` 排序与路径分隔符导致的跨平台摘要不一致）；`node scripts/runtime-manifest.mjs check` OK；HAP 内 `runtime-manifest.json` 与之一致 |
| 二进制审计 | `audit-binaries.sh`、`audit-sources.sh` 通过：随包 ELF 全部 RELRO/NOW/NX=yes；`libiec_server`/`libncploader`/`libdsh_terminal`/`libpython`/`librg` 的 CANARY=yes |
| 发布资产（本地） | `dist/PocketHarness-0.1.0.5-arm64-unsigned.hap`（312,689,580 B）SHA-256 `3d3e12b720b759c8c8b6fa4de6f50e9609fb6a2b7c32e59b2a77284ca04516d9`；`dist/pocket-harness-native-arm64-v8a.zip`（34 个库）SHA-256 `c9241108ad712ea4e40ea2c72935bef145bac540219998686da004e84dba8db1`；`sha256sum -c dist/SHA256SUMS` 通过 |
| 说明 | 本次是默认 debug 构建（`BuildProfile.DEBUG=true`）；release 构建与真机安装仍未验收。命令库（node/python/git/gh 等）未重编，CANARY=no 保留。 |

### 真机覆盖安装（2026-11-18）

- `hdc install -r entry-default-signed.hap` → `install bundle successfully`；设备上 `versionCode=6`、`versionName=0.1.0.5`，应用数据保留。
- 新运行时 `runtime-0.2.2-rc.1-26cc87b18562` 在设备上完成解包：`official-engine.tar.gz` 49,355,576 B、`npm.tar.gz` 2,788,831 B；`.installed` 为 schema 2 JSON，含 `manifestSha256` 与 6 个关键文件哈希。
- 删除 `.installed` 强制整棵重解包两次，进程均存活（观察 200s/240s），无 `THREAD_BLOCK`/`APP_FREEZE`；Web GUI 首屏正常显示，ArkWeb `ExecuteJavaScript` 轮询运行中。
- **已知问题（未定位）**：覆盖安装后的第一次启动曾出现一次闪退；当时未保留日志。随后 3 次启动（含 2 次强制重解包）均未复现，暂记为偶发，后续真机回归时继续观察。

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

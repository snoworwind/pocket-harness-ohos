# DeepSeek Harness · HarmonyOS 原生版

把**官方 DeepSeek Harness** 整个搬进鸿蒙应用：界面就是官方 Web GUI（`dsh --profile web` 的浏览器前端），Agent Loop、工具调用、审批、会话、工作区、终端全部由官方 `@deepseek-ai/dsh` 提供；Bash、Node、toybox、libarchive、ripgrep 针对 `arm64-linux-ohos` 交叉编译成原生库随 HAP 安装，不依赖 adb、Termux 或远程服务器。

> 状态：HAP 已用调试签名安装到真机（SGT-AL10 / HarmonyOS 6.1）并成功启动，界面是官方 Web GUI 的壳：ArkTS 只负责解包引擎、起 `dsh --profile web`、把打印出来的 `http://127.0.0.1:<port>/?token=…` 交给 Web 组件。真机上的引擎启动、界面加载与工具调用链路正在逐项验收，进度见 [验证说明](docs/VALIDATION.md)。

## 组成

```text
ArkUI (entry/src/main/ets)
  ├─ pages/Index.ets            Web 组件 + 启动/失败状态（唯一界面）
  ├─ platform/NativeRuntime.ets 解包引擎、起 dsh web、管理原生命令
  └─ core/OfficialRpc.ts        官方 SDK 的换行 JSON-RPC 适配（旧的自绘界面遗留，
                                当前界面走 Web，保留供宿主机测试使用）

native/iec/                     端侧原生执行核（IEC，来自 Bettersh）
  ├─ platform/ohos/har/         ArkTS 接口 + libiec_server.so
  ├─ exec/、tty/、loader/       进程、终端、ELF 装载
  └─ scripts/optional/          Node、bash、toybox 等交叉编译脚本

scripts/pack-native.sh          把交叉编译产物、官方引擎和前端打进 HAP
scripts/build.ps1               Windows 命令行构建 HAP
scripts/sign-and-install.ps1    签名 + 安装 + 启动（含包名一致性检查）
```

## 设备上真正运行的东西

| 能力 | 实现 | 状态 |
| --- | --- | --- |
| 界面 | 官方 `dsh --profile web` 的 Web GUI，装在 HarmonyOS `Web` 组件里 | 已实现 |
| Agent 引擎 | 官方 `@deepseek-ai/dsh@0.2.2-rc.1`，web profile（291 条插件） | 已打包 |
| 运行时 | 交叉编译的 Node 24.22.1 `libnode.so`（V8 JIT-less，strip 后 114 MB） | 已打包 |
| Shell | 原生 bash 5.3 `libbash.so` | 已打包 |
| 基础命令 | toybox（`ls`、`grep`、`sed`…）、libarchive（`tar`/`cpio`/`unzip`）、`zip` | 已打包 |
| 搜索 | ripgrep 14.1.1 从源码编译为 `librg.so`；`@vscode/ripgrep` 换成指向它的兼容包 | 已打包 |
| 引擎原生插件 | `require_builtin.node`、`system.node`（DeepSeek 官方源码）与 `pty.node`（node-pty 源码），都用本机 OHOS 工具链编译 | 已打包 |
| 解包器 | `libarchive.so.13`（由 `archive_extract.cpp` 在运行期 `dlopen`） | 已打包 |

## 来源规则

HAP 里的二进制只有三种来源：华为官方 SDK、DeepSeek 官方发布物、本机从源码编译。没有第三条来源，也没有塞入第三方预编译二进制。

- 逐项清单（源码版本、构建脚本、许可）：[组件来源](docs/SOURCES.md)；
- 自动核对：`bash scripts/audit-sources.sh`，解包 HAP、比对二进制集合、检查引擎归档里的原生插件，并确认 `npm.tar.gz` 与本次 Node 构建逐字节一致；
- libc++ ABI：所有 C++ 产物必须与随包 `libc++_shared.so` 的 `std::__n1` 命名空间一致（libc++ 22 头文件 + `__config_site` 改成 `__n1`），否则真机 dlopen 时找不到符号。见 [架构](docs/ARCHITECTURE.md)。

## 构建

### 1. 原生运行时（WSL / Linux）

```bash
bash work/bootstrap-native.sh          # 一次性：工具链、sysroot、官方引擎
bash work/prepare-llvm22.sh            # Node 24 的 V8 需要更新的 clang
bash native/toolchain/build-node24.sh  # Node 24（最慢；用 libcxx-ohos 头文件）
bash native/toolchain/build-addons.sh  # require_builtin / system / pty 三个插件
bash scripts/pack-native.sh            # 产物 + 引擎归档 → entry/
```

> `work/` 里的脚本是本机交叉编译环境的历史记录，路径写死在 `/var/tmp/deepseek-harmony-native`。

### 2. HAP 与安装

```powershell
pwsh -File scripts/build.ps1 -DevEcoHome 'D:\D Program Files\DevEco Studio'
# 签名：把带 signingConfigs 的完整配置存成本地 signing.local.profile.json5（已被 .gitignore 排除），build.ps1 会临时套用并在构建后还原
pwsh -File scripts/sign-and-install.ps1 -AppCert <cer> -Profile <p7b> -Keystore <p12> `
  -KeystorePwd ****** -KeyPwd ******
```

`sign-and-install.ps1` 会先比对 Profile 里的 `bundle-name` 与 `AppScope/app.json5` 的 `bundleName`（当前是 `dev.snoworwind.phoh`），不一致直接退出——调试 Profile 是绑定包名的，拿别的项目的材料签名装不上。

### 3. 宿主机测试

```powershell
npm install
npm test
```

另外两个离线校验会解包 HAP 里的引擎归档，用宿主 Node 解析插件表：

```bash
bash scripts/check-engine-dump.sh    # sdk profile：111 个插件
bash scripts/check-engine-web.sh     # web profile：291 个插件（Web GUI 用这套）
```

## 目录与产物

运行时布局（首次启动时解包到应用私有目录）：

```text
filesDir/
  runtime-<version>/
    bin/           命令启动器（#IECSOv2 包装，指向 bundle 里的 .so）
    engine/        官方引擎 + 前端 dist + harmony/ 宿主脚本
    certs/         CA 证书
    home/ tmp/     运行时 HOME 与 TMPDIR
  harness-home/    官方引擎的 DSH_HOME（profile、会话、设置都写这里）
```

## 升级与数据

覆盖安装（同 bundleName、同签名证书、`versionCode` 递增）时，应用数据目录整体保留：

| 内容 | 路径 | 覆盖更新后 |
| --- | --- | --- |
| 会话、模型设置、profile、凭据 | `filesDir/harness-home` | **保留**，应用从不删除这个目录 |
| 解包出的运行时（引擎 + npm + 启动器） | `filesDir/runtime-<内容摘要>` | 按内容换新；旧目录在下次启动成功后自动删除 |

运行时目录名是 `0.2.0-<12 位摘要>`。摘要 = `sha256(应用版本 + 引擎版本 + Node 版本 + official-engine.tar.gz 全文 + npm.tar.gz 全文 + entry/libs 下每个 .so 全文)` 的前 12 位（`scripts/pack-native.sh`）。所以引擎、npm、任一原生库变了都会换目录、重新解包；只改 ArkTS 代码时摘要不变，升级后直接复用，省掉一次 1–2 分钟的解包。引擎归档用固定 `mtime`/排序打包，同样的输入两次打包摘要相同（已验证两次都是同一个值）。

两条必须知道的边界：

- **换签名证书**（debug 换 release、调试证书过期后重新生成）系统会拒绝覆盖安装，只能卸载重装，`harness-home` 会一起消失；
- **降级**：装回旧版本会得到旧的运行时目录，需要重新解包；旧版本的 `runtime-<旧摘要>` 已被删掉，属于预期行为。

### 运行时目录被改坏时

启动时只做三项存在性探测（`.installed`、`engine/.../dsh/lib/bin.js`、`npm/bin/npm-cli.js`）。任一项缺失就整棵重建。如果三项都在、但引擎启动时报 `Cannot find module` / `failed to import` 这类缺文件症状，界面会自动删掉这棵目录重新解包一次（只一次，避免死循环）；仍失败则显示错误，并提供「重新解包运行时」按钮手动触发。`harness-home` 全程不动。

没做的是逐文件内容校验：文件被改成语法合法的内容不会被发现——那需要每次冷启动读一遍 2.5 万个文件，代价与收益不成比例。

## 已知边界

- 首次启动要把 43.8 MB 的引擎归档解成 2.5 万个文件，真机上是一到两分钟，界面期间显示进度文案；
- 后台保活用「定位」连续任务（参考 HiSH）：切后台/锁屏后引擎继续跑，需要授权模糊定位，拒绝时只影响后台存活；
- `dsh web` 只绑 `127.0.0.1`，界面只在本机 Web 组件里可达；不要改成对外监听；
- 引擎自带的进程级沙箱（bwrap / Landlock）在鸿蒙上大概率不可用，能力边界靠 permission preset 与工具开关；
- `fork` 未被拦截，是否允许由设备决定，`probeCaps().fork` 会先探测；终端 PTY 依赖 `forkpty`；
- 未包含：Python、MCP、语音、插件市场、后台常驻执行。

原生组件许可：Bettersh/IEC（随仓库附带 LICENSE）、bash（GPL-3.0，分发需提供对应源码）、toybox（BSD）、libarchive（BSD）、OpenSSL（Apache-2.0）、Node.js（MIT）、官方 DSH 与其原生插件（见各包 LICENSE）。本工程原创代码为 MIT。

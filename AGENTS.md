# AGENTS.md

本文件面向在本仓库工作的自动化编码代理（以及第一次接手的人类开发者），记录**构建方式、必须遵守的架构约束、验证清单和发布流程**。README 讲“这是什么”，这里讲“改哪里、怎么验证、什么不能做”。

---

## 1. 项目形态

- HarmonyOS 应用（bundleName 见 `AppScope/app.json5`）：ArkUI 外壳 + 官方 DeepSeek Harness Web GUI。
- 进程模型：`Index` → `NativeRuntime` → 启动 IEC 原生执行/终端服务 → `node engine/bin.js --profile web` → ArkWeb 加载 `http://127.0.0.1:<port>`；右侧栏终端由 libvterm 原生绘制。
- 运行时目录：`filesDir/runtime-<manifest.version>/`，每次清单版本变化会在设备上整棵重解包并清理旧目录；`harness-home/` 保存会话/设置，升级不删。
- 命令不是 ELF：每个命令是 `runtime-<ver>/bin/<name>` 的 `#IECSOv2` 文本启动器，指向随 HAP 安装的 `.so` 与入口符号，由 IEC 执行服务装载。
- 应用启动时会往 `$DSH_HOME/AGENTS.md` 写入一份**内置全局说明**（每次启动覆盖），DSH 会把它加载进每个会话。用户/项目规则应写在工作区的 `AGENTS.md`，不要改这份内置文件。

关键目录：

| 路径 | 作用 |
| --- | --- |
| `entry/` | ArkTS 应用、HAP 资源（`resources/rawfile/tools/*` 运行时归档）、`libs/<abi>/*.so` |
| `entry/src/main/ets/platform/NativeRuntime.ets` | 运行时准备、命令启动器、环境变量、Web 服务启动 |
| `native/iec/` | IEC 原生执行核：exec/tty/fs shim、loader、服务端、OHOS HAR |
| `native/iec/platform/ohos/har/` | `libiec_server.so`、`libdsh_terminal.so`、`libncploader.so` 的构建与 rawfile |
| `native/terminal/` | libvterm 终端 |
| `plugins/` | DSH 侧插件（harmony-compat、终端、自动审核等） |
| `scripts/` | 构建、打包、清单、测试脚本 |
| `docs/` | ARCHITECTURE / VALIDATION / SOURCES / X86_64-BUILD 等 |
| `.githooks/` | 敏感信息扫描（`npm run hooks:install` 启用） |

---

## 2. 环境与构建

### Windows（应用与 HAP）

需要 DevEco Studio（用 `--deveco-home` 或 `DEVECO_HOME` 指向本机安装目录）与 Node 18+。

```powershell
node scripts/build.mjs                     # 构建 HAP（会先 sync 运行时清单）
node scripts/build.mjs --clean             # 原生库/归档有改动时用，避免增量跳过
node scripts/build.mjs --strict-runtime-manifest   # 发布/CI：清单不匹配直接失败
```

- `build.mjs` 只调用命令行 hvigor，不打开 IDE；签名来自本地 `build-profile.json5`（git 忽略）。
- 产物：`entry/build/default/outputs/default/entry-default-signed.hap` 与 `entry-default-unsigned.hap`。
- `build-profile.json5` 首次构建由 `build-profile.example.json5` 生成；不要提交它或任何签名材料。

### WSL / Linux（原生库）

`native/iec` 的算法/服务端可在宿主测试；交叉编译需要 OHOS SDK 与构建根目录：把 `scripts/env.sh.example` 复制为 `scripts/env.sh`，按本机情况设置 `OHOS_SDK`、`NATIVE_BASE` 等路径。

- 从 Windows 仓库同步源码到 Linux 构建树时**必须转成 LF**；不要把 Windows 生成的 `build-cmake/` 带过去。
- 单个命令库：`bash native/iec/scripts/optional/build_<tool>.sh`（如 `build_git.sh`、`build_gitlfs.sh`、`build_gh.sh`、`build_python.sh`）；ripgrep 用 `bash scripts/rg/build-ripgrep.sh`，node-pty 用 `bash scripts/pty/build-node-pty.sh`。
- 打包回仓库：`bash scripts/pack-native.sh`（缺库会失败；`--partial` 仅用于分阶段验证），它会把 `.so` 复制到 `entry/libs/<abi>/`、复制运行时归档并调用 `runtime-manifest.mjs sync`。
- 运行时清单版本由**实际随包字节**计算，禁止手改 `runtime-manifest.json` 的 `version`。哈希只在构建时临时算、不落盘：`build.mjs` 每次构建前自动 sync，`pack-native.sh` 末尾也会 sync；发布构建加 `--strict-runtime-manifest` 会在清单与归档不一致时直接失败。改原生库或壳层插件不需要 sync：`.so` 直接从 HAP 加载、插件随 rawfile 分发，都不在摘要域里；`pack-native.sh` 也不再把这些插件打进引擎归档。

### 设备

```powershell
# hdc 在 DevEco SDK 的 toolchains 下
hdc list targets
hdc install -r entry-default-signed.hap     # 覆盖安装，保留应用数据
hdc shell aa force-stop <bundleName>
hdc shell aa start -a EntryAbility -b <bundleName>
hdc shell hilog -x | grep -E "IEC_LOGGER|THREAD_BLOCK|APP_FREEZE"
```

- 只有 **debug 签名**（Profile 含设备 UDID）的 HAP 能 `hdc install`；release 签名会报 `9568322`。
- 覆盖安装后若运行时版本变化，首次启动会解包（现在异步进行，见 §3.2），旧运行时在成功后被清理。

---

## 3. 必须遵守的架构约束

### 3.1 平台禁止应用进程 `execve` 任何 ELF

实测 `execve` 对应用数据目录、bundle `libs`、系统动态链接器都返回 `EACCES`；文本启动器返回 `ENOEXEC` 只是因为格式检查先发生。因此：

- **不要**再引入“ELF 启动桩 / 动态链接器加载 / 直接 exec 启动器”的方案；
- 所有命令仍通过 `#IECSOv2` 启动器 + IEC 执行服务启动；
- Go 程序（`git-lfs`、`gh`）需要子进程时走**进程内执行桥**：
  - 公共 C 端：`native/iec/tools/iec_fork_exec.c`（`fork` 后子进程只跑 C，调用链接进来的 `exec/shim.c`，请求执行服务并成为替身）；
  - git-lfs：`native/iec/scripts/optional/gitlfs-ohos/`（`subprocess.Cmd` 对 `$IEC_SYSROOT/bin/*` 生效）；
  - gh：`native/iec/scripts/optional/gh-ohos/`（`internal/run.PrepareCmd` 接入，git 命令都走它）。
  - 构建脚本负责把 Go 源码打补丁与编译 C 文件（`CGO_CFLAGS` 需 `-DINT_PRELOAD`）。

### 3.2 解包不能阻塞 UI 线程

`unpackResource()` 是 `Promise<number>`，rawfile 读取与 tar 解包都在 NAPI 工作线程。不要在 JS 线程上做同步解包，也不要改回同步返回值——首次启动约 11 秒的解包会触发 `THREAD_BLOCK_6S` 看门狗把进程杀掉。UI 只负责 `await` 与展示进度。

### 3.3 启动器与符号链接

- 启动器格式固定（`#IECSOv2` + `.so` + 入口 + arity + 可选启动方式），不要改字段含义。
- 服务端 `ResolveLaunchPath()` 负责把真实符号链接与 fs shim 的 `<name>.IEC_SYMLINK` 标记解析成真实文件；路由在 `onExecute`/`Spawn`/`SpawnShebang` 都要经过它。
- 代码里保留 sidecar 启动器识别，但目前没有命令使用；不要为了“方便”重新引入 ELF 双形态。

### 3.4 Python 运行时布局

- stdlib 在 `<sysroot>/python/lib/python3.12`，`PYTHONHOME=<sysroot>/python`。
- `python-stdlib.tar` 必须包含 `lib/python3.12 -> ../python/lib/python3.12` 兼容链接（设备上落成 `.IEC_SYMLINK`），否则 venv 删掉 `PYTHONHOME` 后找不到 stdlib。
- `venv` 的 CLI 默认必须是复制而不是符号链接（`build_python.sh` 同时改 `EnvBuilder` 默认与 `use_symlinks`）；`_bz2` 缺失视为构建失败。

### 3.5 其它不可回退点

- `node-pty` 的 `pty.node` 必须链接 tty+exec shim 并用 `--wrap` 接管 `forkpty/openpty/posix_openpt/execvp`，不能用 libc 直连。
- 所有 C++ 产物（`libnode.so`、`pty.node`、`require_builtin.node`）必须用 libc++ 22 头文件 + `_LIBCPP_ABI_NAMESPACE __n1` 编译（SDK 的 `libc++_shared.so` 只导出 `__n1`）。
- C++ 服务端逻辑保持“纯函数可测”：路由/解析的判据放 `exec_route.cpp`、`path_resolver.cpp`，宿主测试在 `native/iec/tools/*selftest*`。
- ArkTS 中加新环境变量时放在 `NativeRuntime.buildEnv()`；设备端不存在的绝对路径不要写进二进制。
- 壳层插件（`plugins/harmony-compat`）必须同时保留一份在 `entry/src/main/resources/rawfile/tools/harmony-compat/`：应用启动时优先从 rawfile 同步进 profile；新引擎归档已不再包含它（旧归档里的副本只当兜底）。只改 `plugins/` 不同步 rawfile 会命中 `tests/harmony-plugin-rawfile.cjs`，设备上设置页会少一行。

---

## 4. 验证清单

改完代码至少跑：

```bash
node scripts/test.cjs                 # 宿主测试：会话协议/SSE/路径沙箱/附件钩子/桥脚本顺序/门禁
node scripts/test-fetch-polyfill.cjs  # fetch 补丁语义（16 项）
node tests/fetch-redirect.cjs         # 重定向安全：跨源剥离认证头、HTTPS→HTTP 降级（12 项）
npm run secrets:scan                  # 全仓库敏感信息
node .githooks/secret-scan.mjs --history  # 发版前：历史提交与提交信息
node scripts/runtime-manifest.mjs check
```

改原生执行核（`native/iec`）额外在 WSL 里跑：

```bash
bash native/iec/scripts/test_iec_native_host.sh   # 路由/链接解析/cwd/NCP 分类/sidecar
```

真机验收（有设备时）：

```bash
# 覆盖安装后
hdc shell aa force-stop <bundleName>
hdc shell aa start -a EntryAbility -b <bundleName>
hdc shell hilog -x | grep -E "IEC_LOGGER|THREAD_BLOCK|APP_FREEZE"
```

- 确认 Web GUI 加载（日志里的 `http://127.0.0.1:<port>`、ARKWEB-CONSOLE 的 `DSH_TERM`）。
- 涉及命令链路的改动，在应用终端里跑对应验收（如 `git lfs install/track`、`python -m venv`、`python -c "import bz2"`、`rg -P`）。
- 真机验证过的修复要写进 `docs/VALIDATION.md`，注明“已验证/未验收”，不要把未跑过的写成已通过。

---

## 5. 版本与发布

### 升版本

1. `AppScope/app.json5`：`versionName` 与 `versionCode` 同时加一。
2. `README.md` / `README.en.md` 的版本表。
3. `node scripts/build.mjs --clean`。
4. 提交并推送（tag 指向含版本号的提交）。

### 发布资产（GitHub Release）

- `PocketHarness-<version>-arm64-unsigned.hap`：取 `entry-default-unsigned.hap`，**未签名**。
- `pocket-harness-native-arm64-v8a.zip`：扁平结构，包含 `entry/libs/arm64-v8a/*` 与 HAR 构建产物 `native/iec/platform/ohos/har/build/default/intermediates/libs/default/arm64-v8a/*`（`libc++_shared.so`、`libdsh_terminal.so`、`libiec_server.so`、`libncploader.so`），以及 `libarchive.so.13`。
- 默认只发布 **arm64** 预编译包；需要 x86_64 运行时请按 `docs/X86_64-BUILD.md` 自行构建。
- **原生库 zip 不要每个版本重打**：只有 `native/`（含 HAR 源码）变化时才重新生成；纯 ArkTS/JS/插件版本直接沿用上一个 Release 的同一份资产（SHA-256 不变），发布说明里注明“沿用”。HAP 仍然每个版本重新构建。
- Release 说明里附两个资产的 SHA-256，并注明“未签名、需自行签名安装”。

```bash
gh release create vX.Y.Z.Z --title "Pocket Harness X.Y.Z.Z" \
  --notes-file notes.md \
  PocketHarness-X.Y.Z.Z-arm64-unsigned.hap \
  pocket-harness-native-arm64-v8a.zip
```

发布前确认：`git status` 干净、tag 指向版本提交、资产摘要与说明一致。

---

## 6. 安全与仓库卫生

- **禁止提交**：`.sign/`、`signing.local.profile.json5`、根 `build-profile.json5`、`local.properties`、`.env*`、`*.p12`/`*.p7b`/`*.cer`/`*.jks`/`*.keystore`、`extra-ca.pem`、任何 token/私钥。
- **禁止在文档/提交里写真实设备标识**（SN/IMEI/MAC/手机号）和本机用户名路径；用“真机”“测试机 A”代替。
- `entry/libs/`、`entry/src/main/resources/rawfile/tools/*.tar*`、HAP/`.app`、构建目录都在 `.gitignore` 中，不要 `git add -f` 提交。
- 建议每台开发机执行 `npm run hooks:install`；提交/推送前也可手动 `npm run secrets:scan`。服务端 GitHub Actions 也会跑敏感扫描。
  - **设备端（HarmonyOS 沙箱）例外，不要跑 `hooks:install`**：应用进程无法 `execve` 普通脚本，钩子里的 `#!/bin/sh` 解析不到解释器，`core.hooksPath=.githooks` 会让 `git hook run pre-commit` 返回 127、**每次 `git commit` 直接失败**。设备上应改为在 `.git/hooks/` 放包装脚本，shebang 写 `$IEC_SYSROOT/bin/sh` 的**真实绝对路径**，正文 `exec node .githooks/secret-scan.mjs --staged`（`pre-push` 用 `--pre-push`），并确认 `git config core.hooksPath` 为空。`.git/hooks/` 不入库，绝对路径可按机器写。详见 `.githooks/README.md`。
- 提交信息沿用现有风格（`fix(runtime): ...` / `chore(release): ...`），说明“根因 → 修复 → 验证”。

---

## 7. 已知限制（不要误当 bug 修）

- 鸿蒙上 Node 以 `--jitless` 运行：没有 WebAssembly，fetch 由 `harmony/fetch-polyfill.cjs` 提供。
- 设备端没有 `make`/`cc`；带原生扩展的 pip/npm 包需在构建机预编译。
- Python `_uuid`、`_tkinter` 未编入；`uuid` 有纯 Python 回退，无 Tk。
- `gh` 少数非 git 的直接 `exec.Command` 路径（`gh cs ssh`、内置 pager、扩展安装等）尚未接入执行桥；git 子命令已验证可用。
- 应用市场分发暂不计划；release 签名 HAP 不能 `hdc install`。
- 后台保活仍用 LOCATION 连续任务（隐私取舍有意保留，见 `docs/SECURITY.md`）；`auto` 预设默认不注册，需 `harmony-native.json` 显式开启 autoReview。

---

## 8. 文档索引

- [README.md](README.md)：功能、构建、签名与分发。
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：运行架构、exec/tty 模型、平台约束。
- [docs/VALIDATION.md](docs/VALIDATION.md)：逐轮修复与验证记录（含未验收项）。
- [docs/SOURCES.md](docs/SOURCES.md)：二进制来源规则与组件清单。
- [docs/SECURITY.md](docs/SECURITY.md)：安全边界、同 UID/插件信任模型与接受风险。
- [docs/X86_64-BUILD.md](docs/X86_64-BUILD.md)：模拟器运行时自行构建。
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：许可证与第三方声明。

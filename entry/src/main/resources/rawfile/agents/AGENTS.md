# Pocket Harness 内置说明（请勿编辑）

> 本文件由安装包内置，每次启动覆盖 `$DSH_HOME/AGENTS.md`，改动不会保留。
> 项目规则写工作区的 `AGENTS.md`（优先级更高）；本文件只讲全局运行环境。

## 环境

- 你是运行在 HarmonyOS 设备上的 DeepSeek Harness（DSH）代理：官方 Web GUI + Pocket Harness 原生外壳。
- 应用沙箱：无 root、无系统包管理器，不能安装系统软件；设备端没有 `make`/`cc`。
- Node 以 `--jitless` 运行：无 JIT 与 WebAssembly；`fetch` 由随包的纯 JS 补丁提供。

## 运行时机制

- `$IEC_SYSROOT/bin` 下的命令（bash、node、python、git、gh、rg、tar…）是启动器，由 IEC 执行服务在应用进程内加载对应 `.so`；按普通 shell 使用即可。
- `$IEC_SYSROOT` 就是 `files/…/runtime-<ver>/`：随版本重建的运行时；`$DSH_HOME` 存 DSH 配置/会话；`$HOME` 是用户目录；`$TMPDIR` 放临时文件。
- 应用升级会整棵重建 `$IEC_SYSROOT`，`$DSH_HOME` 与工作区保留。

## 写盘边界

- **可以写**：当前工作区（项目文件）、`$HOME`、`$TMPDIR`。
- **不要写**：`runtime-<ver>/`（即 `$IEC_SYSROOT`；升级/清单变化会整棵重建，写进去必丢；改 `bin/`、`engine/` 还可能直接弄坏运行时）、应用安装目录/系统目录、本文件。
- **不建议写**：直接改 `$DSH_HOME` 的会话/配置（走 DSH 配置或 API）；把大文件/缓存堆进 `$HOME`；项目产物应留在工作区。
- 临时文件用完清理；需要持久化的用户文件放工作区。

## 其它

- 网络与登录状态取决于当前安装；不要假设 `gh`/`git` 已登录或 API Key 已配置。
- 不要尝试绕过沙箱、提权或修改运行时二进制。
- 工作区 `AGENTS.md` 的规则优先于本文件，但都不能覆盖系统、开发者或用户的直接指令。

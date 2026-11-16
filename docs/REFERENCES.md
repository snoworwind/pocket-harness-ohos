# 参考与差异

调研快照：2026-11-15。三个参考项目只用来确定方向：端侧执行核、能力隔离、移动端会话交互。本工程的 Agent Loop 不再自实现，改用官方 DeepSeek Harness。

| 参考项目 | 借鉴点 | 本工程取舍 |
| --- | --- | --- |
| [Guncat Work for hmos](https://github.com/zhubowen-bot/Guncat-Work-for-hmos) | ArkTS/ArkUI 工作台、端侧 IEC 执行核（Bettersh）、HAR 接入方式 | 复用其 IEC HAR（见 `native/iec`，保留上游 LICENSE），界面与业务代码本工程自写 |
| [Pocket Harness](https://github.com/snoworwind/pocket-harness) | 宿主能力边界、授权收口、运行状态恢复 | 不引入 Android WebView、Termux、Shizuku；审批与提问走官方 SDK 的宿主请求 |
| [DSH Go](https://github.com/ccch1mneyyy/dsh-Go) | 移动端会话、工具审批、任务停止 | 不移植 Flutter 与远程协议；停止语义按官方「无单轮取消」实现 |

## 与官方引擎的关系

引擎是 npm 上的 `@deepseek-ai/dsh@0.2.2-rc.1`，以 `--profile web` 启动：本工程解包官方前端，用 Web 组件加载 `dsh` 打印的 `http://127.0.0.1:<port>/?token=…`，界面与 Agent Loop 都来自官方。仓库里还保留了官方 SDK 的 JSON-RPC 适配（`core/OfficialRpc.ts`，每行一个 JSON-RPC 2.0 帧，`initialize` 必须最先调用，宿主请求有 `approval/request`、`user-question/ask`，没有单轮取消方法），供宿主机测试与旧链路使用，当前界面不走它。

## 原生工具链

- HarmonyOS SDK / NDK：DevEco Studio 自带 `sdk/default/openharmony`（API 24，sysroot 与 CMake）。
- 编译器：OpenHarmony clang 15 用于一般工具；Node 24 的 V8 需要 C++20 与更新的内建头，改用 Ubuntu 的 LLVM 22 驱动 + OHOS sysroot。
- 参考上游构建脚本：Bettersh 的 `iec/scripts/optional/build_node.sh`、`build_toybox.sh`、`build_libarchive.sh` 等，本工程在其上补充 Node 24.22.1 与工具链修正。

## 许可

| 组件 | 许可 | 说明 |
| --- | --- | --- |
| 本工程原创代码（ArkTS、脚本、文档） | MIT | 见 `LICENSE` |
| `native/iec`（Bettersh / Guncat） | 见 `native/BETTERSH-LICENSE`、`native/GUNCAT-LICENSE` | 复用其执行核与 HAR |
| Bash 5.3 | GPL-3.0 | 分发生成的 `libbash.so` 需按 GPL 提供对应源码 |
| toybox | BSD | |
| libarchive | BSD-2-Clause | |
| OpenSSL 3.0 | Apache-2.0 | |
| pcre2 | BSD-3-Clause | |
| Node.js 24 | MIT | 含 V8、ICU 等第三方组件，各自许可保留在 Node 源码树内 |
| `@deepseek-ai/dsh` 及其依赖 | 见各包 `LICENSE` | 随应用打包的是未修改的 npm 产物 |

打包的引擎来自 npm 安装结果，裁剪只删除文件，不修改代码。若后续为鸿蒙打补丁，需要把补丁与依据写进 `docs/VALIDATION.md`。

# 第三方软件声明

本应用 **pocket-harness-ohos（Pocket Harness，HarmonyOS 原生版）** 是第三方（非官方）项目，与 DeepSeek 没有隶属、
赞助或背书关系。"DeepSeek"、"DeepSeek Harness" 名称及鲸鱼标识归 DeepSeek 所有，本项目仅在
描述所兼容的上游软件时使用它们。

本文件汇总随应用分发的第三方组件及其许可证。许可证全文见 `LICENSES/` 目录，同一份文件也随
HAP 分发（应用内路径 `resources/rawfile/notices/`，首次启动后解出到应用沙箱的 `files/notices/`）。

## 组件清单

| 组件 | 版本 / 来源 | 许可证 | 提示文本 |
| --- | --- | --- | --- |
| DeepSeek Harness（`@deepseek-ai/dsh` 及官方包） | 0.2.2-rc.1，npm 官方发布物 | MIT | `LICENSES/DSH-MIT.txt`；引擎归档内每个 npm 包另带自己的 `LICENSE`（735 份） |
| 本工程原创代码（ArkTS 壳、IEC 适配、终端插件、鸿蒙适配插件） | 本仓库 | MIT | `LICENSE` |
| `@local/dsh-harmony-terminal`（原生终端 tab） | `plugins/dsh-harmony-terminal` | MIT | `LICENSE` |
| `@deepseek-ai/dsh-harmony-compat`（鸿蒙适配：返回手势状态、引用浮层） | `plugins/harmony-compat` | MIT | `LICENSE` |
| GNU Bash | 5.3，<https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz>，未打补丁 | GPL-3.0 | `LICENSES/GPL-3.0.txt` |
| Node.js | v24.22.1，<https://nodejs.org>（源码包） | MIT | `LICENSES/Node-MIT.txt` |
| npm | 11.19.1（Node.js 源码树 `deps/npm`） | Artistic-2.0 | `LICENSES/Artistic-2.0.txt` |
| toybox | 0.8.14 | 0BSD | `LICENSES/toybox.txt` |
| libarchive（bsdtar / bsdcpio / unzip / zipcmd） | 3.7.7 | BSD-2-Clause | `LICENSES/libarchive.txt` |
| ripgrep | 14.1.1 | Unlicense OR MIT | `LICENSES/ripgrep-UNLICENSE.txt`、`LICENSES/ripgrep-MIT.txt` |
| libvterm | 随仓库源码 | MIT | `LICENSES/libvterm.txt` |
| libc++（`libc++_shared.so`） | DevEco Studio SDK 自带 | Apache-2.0 WITH LLVM-exception | `LICENSES/Apache-2.0-LLVM.txt` |
| IEC / Bettersh / Guncat | 本仓库 `native/iec` | MIT | `native/iec/LICENSE`、`native/BETTERSH-LICENSE`、`native/GUNCAT-LICENSE` |
| node-pty（`pty.node`） | 1.2.0-beta.15 源码 | MIT | 见上游 `LICENSE` |
| `@deepseek-ai/node-addon-system`（`system.node`） | 官方源码 | BSD-3-Clause | 见上游 `LICENSE` |
| `@deepseek-ai/dsh-node-addon-require-builtin` | 官方源码 | MIT | 见上游 `LICENSE` |
| `@vscode/ripgrep` 兼容包 | 本工程重写 | MIT | `LICENSE` |
| Mozilla CA 根证书集（`cacert.pem`） | Mozilla，纯数据 | MPL-2.0（数据本身为公开证书） | <https://www.mozilla.org/MPL/2.0/> |
| 可选附加 CA（`extra-ca.pem`） | 用户自行提供（不随仓库分发） | 由提供者负责 | 用于会拦截 HTTPS 的开发环境 |

## GNU Bash 的对应源码

分发的 `libbash.so` 由 GNU Bash 5.3 的**原样源码**交叉编译得到，没有修改上游源码：

- 源码包：<https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz>，构建脚本会记录其 SHA-256；
- 编译参数与工具链见本仓库 `native/build-bash.sh`；
- 与该二进制一起链接的 IEC shim 源码在本仓库 `native/iec`（MIT）；
- 如果上述地址不可用，可通过本仓库的 Issue 向维护者索取对应源码。

GPL-3.0 全文见 `LICENSES/GPL-3.0.txt`。

## 对上游 DSH 的修改

本应用没有修改 `@deepseek-ai/dsh` 的源码，只做了三件事：

1. 在 profile 里新增客户端插件 `@local/dsh-harmony-terminal`，把右侧栏终端交给系统原生渲染；
2. 在 profile 里新增客户端插件 `@deepseek-ai/dsh-harmony-compat`，提供返回手势所需的浮层状态上报与引用浮层定位；
3. 在 profile 补丁里禁用自带 Web 终端插件（`ui-sidebar-terminal`），因为它依赖的 PTY 在鸿蒙沙箱内不可用。

DSH 采用 MIT 许可，上述修改与再分发均在许可范围内。

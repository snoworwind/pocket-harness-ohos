# 验证说明

记录截至 2026-11-16 的验证范围。凡是没在真机上跑过的条目都明确标为「未验收」，不写成已通过。测试设备为一台 HarmonyOS 6.1（API 26）手机与 x86_64 模拟器。

## 已确认

| 项目 | 操作 | 结果 |
| --- | --- | --- |
| ArkTS 构建 | `node scripts/build.mjs` | `BUILD SUCCESSFUL` |
| arm64 运行时 | 交叉编译 Node 24.22.1 / Bash 5.3 / toybox / libarchive / ripgrep | 全部产物随 HAP 打包 |
| 发布签名构建 | release 证书 + `PocketHarnessRelease` signingConfig | 签名 HAP 与 `.app` 均构建成功 |
| 上架包 | project 模式 `assembleApp` | `build/outputs/default/*.app`，`pack.info` 中 bundle 与版本一致 |
| release HAP 安装 | `hdc install` | 被拒：`9568322 signature verification failed due to not trusted app source`（发布签名不能侧载，符合预期） |
| 调试签名安装 | debug Profile + `hdc install -r` | `install bundle successfully`，`aa start` 后首屏渲染正常（本次改包名前） |
| 官方 Web GUI | 真机 | `dsh --profile web` 启动后 Web 组件加载出官方界面 |
| 原生终端 | 真机 | bash 正常启动；`pwd` 落在当前会话工作目录；`Ctrl-Z`/`fg` 作业控制可用 |
| 终端崩溃修复 | 真机 | `runtime-manifest.json` 给 bash/sh 补 `"arity": 3` 后不再 139 |
| 返回手势 | 真机 | 菜单 → 设置 → 右侧栏/终端 → 左侧抽屉逐层关闭；无浮层时交回系统 |
| 引用浮层 | 真机 | 「引用文本」按钮出现在选区下方 |
| 双指缩放 | 真机 | 已禁用 |
| fetch 补丁 | 真机终端 | JSON、gzip、FormData multipart、SSE、AbortError、外部 HTTPS 均通过 |
| 引擎插件表 | `bash scripts/check-engine-web.sh` | web profile 291 个插件，stderr 为空 |
| 宿主机测试 | `node scripts/test.cjs` | 28 项通过 |
| fetch 回归 | `node scripts/test-fetch-polyfill.cjs` | 15 项通过 |

## 未验收

- 新包名 `com.snoworwind.phoh` 的 debug Profile 侧载安装（需要重新生成自动签名）；
- 应用市场实际审核与上架；
- 后台保活：授权模糊定位后切后台/锁屏，引擎是否持续运行、通知栏行为与持续时间；
- 模型调用工具（`bash`/`rg`/文件工具）、工作区目录选择、文件上传、审批面板的完整链路；
- 登录 / API Key 配置后的真实对话，以及各类网络环境下内置 CA 是否覆盖实际证书链；
- JIT-less V8 的长任务性能与内存占用。

## 已知缺口与假设

1. **两套 C++ ABI 怎么对齐**：`libiec_server.so` 由 hvigor 用 SDK 头文件构建、引用 `__n1`；交叉编译的产物必须用同名空间。V8 又需要 libc++ 22 的 `<ranges>`，做法是「libc++ 22 头文件 + `__config_site` 改成 `__n1`」，用 `scripts/probe-ranges-n1.sh` 验证过 ranges 能编译且 `-z defs` 链接随包 `libc++_shared.so` 全解析。
2. **引擎归档**只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与 `prebuilds/`，不按 `doc`/`locale`/`test` 目录名删除——这些文件在真机上确实会被用到。生成与校验见 `scripts/engine-prune/finalize-ship-list.sh`。
3. **追加进引擎树的三个原生插件**按运行期加载器的本地构建路径摆放（`node-addon-require-builtin/build/napi/…`、`@deepseek-ai/node-addon-system-linux-arm64/bin/{musl,gnu}/`、`node-pty/build/Release/`），两套 libc 目录各放一份。
4. **引擎需要可写的 `DSH_HOME`**（`filesDir/harness-home`）；只读目录会在插件挂载前失败。
5. 组件来源规则与逐项清单见 [组件来源](SOURCES.md)。

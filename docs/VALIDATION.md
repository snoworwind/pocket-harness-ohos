# 验证说明

记录截至 2026-11-17 的验证范围。凡是没在真机上跑过的条目都明确标为「未验收」，不写成已通过。测试设备为一台 HarmonyOS 6.1（API 26）手机与 x86_64 模拟器。

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

## 已知缺口与假设

1. **两套 C++ ABI 怎么对齐**：`libiec_server.so` 由 hvigor 用 SDK 头文件构建、引用 `__n1`；交叉编译的产物必须用同名空间。V8 又需要 libc++ 22 的 `<ranges>`，做法是「libc++ 22 头文件 + `__config_site` 改成 `__n1`」，用 `scripts/probe-ranges-n1.sh` 验证过 ranges 能编译且 `-z defs` 链接随包 `libc++_shared.so` 全解析。
2. **引擎归档**只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与 `prebuilds/`，不按 `doc`/`locale`/`test` 目录名删除——这些文件在真机上确实会被用到。生成与校验见 `scripts/engine-prune/finalize-ship-list.sh`。
3. **追加进引擎树的三个原生插件**按运行期加载器的本地构建路径摆放（`node-addon-require-builtin/build/napi/…`、`@deepseek-ai/node-addon-system-linux-arm64/bin/{musl,gnu}/`、`node-pty/build/Release/`），两套 libc 目录各放一份。
4. **引擎需要可写的 `DSH_HOME`**（`filesDir/harness-home`）；只读目录会在插件挂载前失败。
5. 组件来源规则与逐项清单见 [组件来源](SOURCES.md)。
6. **解包期间 UI 会停顿**：`unpackResource()` 是同步调用，启动页能显示「正在解包」，但进度圈动画会停住；要让动画持续需要把解包移出 UI 线程或增加原生进度回调。
7. **运行时清单自动化只覆盖命令行构建**：直接使用 DevEco IDE 的 Build 不经过 `scripts/build.mjs`，不会执行 sync/check；发布构建应统一使用 `build.mjs`，或给 hvigor 增加预构建任务。
8. **`runtime-preload.cjs` 会改变无参 `process.report.getReport()` 的返回**：应用运行时里无参调用只返回 `{ header: {} }`，用于跳过约 30s 的 CPU/network 枚举；需要完整诊断报告时设 `DSH_LITE_REPORT=0`。带 options 的调用不受影响。

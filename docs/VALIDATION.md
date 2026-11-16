# 验证说明

记录截至 2026-11-15 的实际验证范围。工程位置：`D:\forGithub\deepseek-harmony`。凡是没在真机上跑过的条目都明确标为「未验收」，不写成已通过。

## 真机上已经确认的

设备：SGT-AL10，HarmonyOS 6.1（API 26），UDID `32756549A2…ED503`。

| 项目 | 操作 | 结果 |
| --- | --- | --- |
| 调试签名 | DevEco 自动签名生成 `~/.ohos/config/default_deepseek-harmony_…{cer,p12,p7b}` | Profile `bundle-name` = `dev.snoworwind.phoh`、`type` = debug、device-ids 含本机 UDID |
| 构建签名 HAP | `node scripts/build.mjs` + `signingConfig` | `entry-default-signed.hap`，169,452,498 字节 |
| 本地验签 | `hap-sign-tool.jar verify-app` | `Verify success`，SHA-256 摘要一致 |
| 安装 | `hdc install -r` | `install bundle successfully`，`bm dump` 显示 `appProvisionType: debug`、`versionName 0.2.0` |
| 启动 | `aa start -a EntryAbility -b dev.snoworwind.phoh` | `start ability successfully`，应用进程存活，首屏渲染正常 |
| 官方 Web GUI | 真机截图 | `dsh --profile web` 起来后 Web 组件加载出官方界面（首次进入弹「开始使用 / 登录 DeepSeek 账号，或添加 API Key」） |
| 覆盖式升级 | 用新摘要的 HAP `hdc install -r`，不清数据 | `runtime-0.2.0` 被删除、新建 `runtime-0.2.0-ee001db1d404`（447 MB）；`harness-home` 内容保留（`profiles/web/*`、`.credentials.yaml`、`sessions/`）；启动后官方界面正常 |
| 未签名 HAP | `hdc install entry-default-unsigned.hap` | 被拒：`code:9568320 error: no signature file`（签名确实生效） |

真机上暴露并已修掉的问题：

1. **解包必然失败**：`unpackResource()` 依赖运行期 `dlopen` 的 `libarchive.so.13`，但 `pack-native.sh` 的库清单里没有它，HAP 里也就没有；首启解包因此返回非 0。已把 `libarchive.so.13` 加入清单并复制进 `entry/libs/arm64-v8a`。
2. **失败后无法重试**：`fs.mkdirSync(path, true)` 在目录已存在时抛 `13900015 File exists`。已改成先 `accessSync` 再建目录，并在解包失败时清掉半棵树。
3. **libnode.so 装载失败**：`_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`。随包 `libc++_shared.so` 只导出 `std::__n1`，而 `libnode.so` 用 `__1` 头文件编出来。修法：libc++ 22 头文件 + `_LIBCPP_ABI_NAMESPACE __n1`；`libnode.so` 与三个 `.node` 全部重编，`__1` 未定义符号归零。
4. **`std::__n1::__hash_memory` 缺失**：修好命名空间后，运行库仍比 libc++ 22 头文件旧，缺这一个符号。`native/iec/scripts/optional/node-ohos/libcxx_abi_compat.cc` 按 libc++ 实现补上并链进 `libnode.so`。
5. **`require_builtin.node` 产品号错**：编译时用了 `-DNARB_PRODUCT=2`（internal-loader），引擎加载校验报 `native binding product mismatch ... expected require-builtin`。改成 `1`，并在 `build-addons.sh` 里加编译后自检。
6. **引擎裁剪删掉了运行期代码**：先是 `yaml/dist/doc/directives.js`，再是嵌套 `zod/v4/locales/index.js`。改成只删 `.d.ts` / `.map` / `.ts` 源码 / `.md` / `.pdb` / `prebuilds`，不再按 `doc(s)`、`locale(s)`、`test(s)` 目录名删；同时把 `peerDependencies` 纳入闭包（`dsh-scope` 就是被漏掉的）。新增 `scripts/engine-prune/scan-imports.mjs`（裸包 + 相对 import 双重扫描）与 `finalize-ship-list.sh`（静态扫描 + sdk/web 双 dump 校验）。
7. **升级陷阱**：运行时目录名原来只写 `0.2.0`，换引擎不换目录会复用旧解包。现在目录名带内容摘要，启动成功后删除旧的 `runtime-*`。

## 离线已验证

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| ArkTS 编译 | `node scripts/build.mjs --deveco-home '…'` | `BUILD SUCCESSFUL` |
| 宿主机测试 | `node scripts/test.cjs` | 28 项通过（会话协议、SSE、路径沙箱、官方 JSON-RPC 适配） |
| sdk profile 解析 | `bash scripts/check-engine-dump.sh` | 退出码 0、111 个插件、stderr 为空 |
| web profile 解析 | `bash scripts/check-engine-web.sh` | 退出码 0、291 个插件、stderr 为空（官方 Web GUI 的插件表） |
| 前端资源 | 检查 `official-engine.tar.gz` | 含 `@deepseek-ai/dsh-web-frontend/dist`（101 个条目，含 `assets/`） |
| libc++ ABI 核对 | `bash scripts/check-libcxx-abi.sh`、`scripts/probe-libcxx-abi.sh` | 随包 `libc++_shared.so` 为 `std::__n1`；用 `libcxx-ohos` 头文件编译的 probe 链接通过、符号全部落在 `__n1` |
| 原生插件重编 | `bash native/toolchain/build-addons.sh` | `require_builtin.node` 107,680 / `system.node` 18,928 / `pty.node` 70,208 字节，均引用 `__n1` |
| libnode 重编 | `bash scripts/rebuild-node-ranges.sh` + `scripts/strip-libnode.sh` | `libnode.so` 114,161,560 字节，`std::__1` 未定义符号 0、`std::__n1` 137，保留 102 个 `iec_*_main` / `__wrap_*` 导出 |
| HAP 二进制审计 | `bash scripts/audit-sources.sh` | 12 个 `.so` 与预期集合完全一致、无额外文件；`libarchive.so.13` 在列；`npm.tar.gz` 与本次构建逐字节一致 |
| 签名 HAP 体积 | 构建产物 | 169,452,498 字节（`libnode.so` 114 MB + 引擎归档 39.2 MB） |

## 未验收

- 运行时自愈：删掉 `.installed` 后冷启动会整棵重解（真机验证过）；「引擎目录缺文件但三项探测都通过」的自动重解路径只能靠代码审查——`hdc shell` 没有权限改动 `engine/` 这些 755 子目录，无法在真机造出那种损坏。
- 后台保活：`BackgroundMode.LOCATION` 连续任务需要用户授权模糊定位；授权后切后台/锁屏时引擎是否继续跑、通知栏是否显示、持续多久，都要真机确认。
- 引擎能力面：模型调用工具（`bash`/`rg`/文件工具）、终端与 PTY（`forkpty`）、工作区目录选择、文件上传、审批面板。
- 登录 / API Key 配置后的真实对话与网络连通性：`DEEPSEEK_BASE_URL`、内置 CA 是否覆盖实际证书链。
- `probeCaps().fork` 的细节结果（当前设备已通过，否则不会走到引擎启动）。
- JIT-less V8 的长任务性能与内存占用（应用常驻约 300–400 MB）。

## 已知缺口与假设

1. **两套 C++ ABI 怎么对齐**：`libiec_server.so` 由 hvigor 用 SDK 头文件构建、引用 `__n1`；我们交叉编译的产物必须用同名空间。V8 又需要 libc++ 22 的 `<ranges>`。做法是「libc++ 22 头文件 + `__config_site` 改成 `__n1`」，用 `scripts/probe-ranges-n1.sh` 验证过 ranges 代码能编译且 `-z defs` 链接随包 `libc++_shared.so` 全解析。
2. 引擎归档（43.8 MB gzip / 25,606 个文件 / 572 个包）只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与 `prebuilds/`，不再按 `doc`/`locale`/`test` 目录名删除——那两类文件在真机上确实被用到。生成与校验见 `scripts/engine-prune/finalize-ship-list.sh`。
3. 追加进引擎树的三个插件按运行期加载器的本地构建路径摆放（`node-addon-require-builtin/build/napi/napi-v9-linux-arm64-{musl,gnu}/`、`@deepseek-ai/node-addon-system-linux-arm64/bin/{musl,gnu}/`、`node-pty/build/Release/`），两套 libc 目录各放一份。
4. 引擎需要可写的 `DSH_HOME`（`filesDir/harness-home`）；只读目录会在插件挂载前失败。
5. 组件来源规则与逐项清单见 [组件来源](SOURCES.md)。

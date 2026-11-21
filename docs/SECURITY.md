# 安全与信任模型

本文说明 Pocket Harness 实际保护的边界、依赖的信任假设，以及已知的接受风险。它配合
2026-11-18 的安全审查整改（报告 `SECURITY-REVIEW-2026-11-18.md`）编写；逐项验证状态见
[docs/VALIDATION.md](VALIDATION.md)。

## 1. 边界

```text
系统浏览器 / 其它应用
        │  （不能访问 127.0.0.1 之外的监听）
        ▼
WebView（只加载 http://127.0.0.1:<port>）
        │  nonce + origin 限制的桥
        ▼
ArkTS 壳层（Index / NativeRuntime）
        │  IEC 执行服务（unix socket，调用者身份校验）
        ▼
DSH 引擎 + 原生运行时（同 UID）
```

- **Web 服务**只监听 `127.0.0.1`，未带 token 的请求返回 401，带恶意 `Origin` 的请求
  返回 403。token 由服务端生成、经 stdout 交给壳层，不出现在命令行参数里。
- **WebView 只加载本地 origin**。主框架导航只放行当前 `http://127.0.0.1:<port>`
  origin；`data:`/`blob:`/`javascript:`/`file:` 等 scheme 直接拦截，站外 http(s)
  交给系统浏览器。`fileAccess`/`databaseAccess` 已关闭。
- **页面 → 壳层的桥需要 nonce**。终端与下载桥的每条消息都带本次启动的随机
  UUID（文档起点注入 `window.__dshNonce`），`DSH_TERM:` 与 `dshNative.put` 的 id
  都校验这个 nonce；`javaScriptProxy.permission` 与 `scriptRules` 只覆盖本地
  origin。下载分片有单分片、单任务总字节、并发任务与超时上限。
- **执行服务校验调用者**。`SO_PEERCRED` 不可用时拒绝请求；TTY 绑定创建者身份，
  非归属者不能改终端属性；延迟 `SIGKILL` 前比对 `/proc/<pid>/stat` 的 `starttime`，
  避免 pid 复用误杀。
- **归档解包 fail-closed**。除 `..` 检查外，硬链接/符号链接目标越出目标目录时直接
  拒绝该条目；启用 libarchive 的 `SECURE_SYMLINKS`/`SECURE_NOABSOLUTEPATHS`。
- **日志默认脱敏**。壳层 `dsh.log`/`web-error.log` 与原生 `iec-*.log` 在写盘前统一
  抹掉 `token=`、`Authorization`、`Bearer`、`*_KEY`/`*_TOKEN`、`password`、`secret`
  等值；文件 sink 按 4 MiB 轮转并限制历史文件数量。
- **运行时完整性抽查**。`.installed` 记录版本号与关键文件（`bin/node`、`bin/bash`、
  引擎 `bin.js`、npm CLI、Python stdlib 入口）的 SHA-256，启动时重算比对；不符时
  整棵重解 `runtime-<version>`，不触碰 `harness-home` 用户数据。

## 2. 信任假设

- **同 UID 即信任**：DSH 引擎、随包插件、用户插件、Agent 启动的命令与壳层运行在
  同一个应用沙箱、同一个 UID 下。能执行命令的 Agent 或第三方插件可以读写应用私有
  目录，也可以改写 `.installed` 与运行时文件。完整性抽查能发现“只改文件、不改标记”
  的意外损坏或部分篡改，但**不能抵御同 UID 的主动攻击**。
- **安装插件 = 完全信任**。`PluginGuard` 只做启动失败隔离、清单与 `.node` ABI 检查，
  不是权限沙箱。只安装来源可信的插件。
- **HAP 未签名分发**：GitHub Release 提供的是未签名 HAP，安装前应自行核对发布页的
  SHA-256 并完成签名。已签名的 release HAP 不能 `hdc install`。
- **模型与工具能力**：官方引擎的 permission preset / 审批策略是主要的能力闸门；
  默认保持 `workspace-write + ask`。实验性的 `auto` 预设（`danger-full-access` +
  LLM 自动批准）不再默认注册，需要显式设置。
- **WebView 调试**：只在 debug 构建开启；release 构建显式关闭。能使用 `hdc`/DevTools
  的人仍可调试 **debug 包**，不要把 debug 包分发给他人。

## 3. 已知接受风险

| 风险 | 状态 / 理由 |
| --- | --- |
| 后台保活使用定位连续任务（`APPROXIMATELY_LOCATION`、`LOCATION_IN_BACKGROUND`、`backgroundModes: ["location"]`） | **明确保留**：这是鸿蒙上维持引擎后台执行的可用手段；保活是用户主动开启的开关，拒绝定位只影响后台存活。若后续上架或引入位置数据，必须重新评估权限与告知文案。 |
| 同 UID 可篡改运行时与 `.installed` | 见上“同 UID 即信任”；逐文件基线由设备首次安装时生成，随包清单暂无逐文件签名。 |
| 第三方插件无沙箱 | 见上“安装插件 = 完全信任”。 |
| WebView 同源预览可读取 `window.__dshNonce` | nonce 防止跨源伪造，不隔离同源内容；若引擎以同源方式渲染不可信 HTML，仍可调用下载桥。后续应把预览放到独立 origin。 |
| `auto` 预设可被显式开启 | 默认关闭；在 `harness-home/harmony-native.json` 写 `{"autoReview": true}` 并重启才注册，开启后由 LLM reviewer 自动裁决，存在提示注入绕过人工确认的风险。**开启状态跨更新保留**：只有显式写成 `false` 或删除插入行才会关闭；旧版本默认安装过的行会按「用户此前在用」沿用并固化选择。 |
| 上游源码/二进制未全部固定 SHA-256 | **已补齐**：有官方 SHA-256/commit 的按官方值固定；上游只发布 PGP/SHA-512 的条目，固定“按官方下载地址计算”的可复现 SHA-256，并在 [SOURCES.md](SOURCES.md) 标注依据。任何上游字节变化都会让构建失败。 |
| 历史提交含开发环境公开 CA 与早期构建模板 | 历史中发现一次提交过 `extra-ca.pem`（Kaspersky 公开根证书，1273 字节，无私钥）和两份无签名口令的 `build-profile.json5` 模板，均已移出版本库。`secret-scan --history` 按精确 blob SHA-256 豁免这两类历史内容；同名文件以不同内容再次出现仍会被拦截。 |

## 4. 报告问题

请通过仓库 Issue 私下联系维护者，不要在公开 Issue 中粘贴完整 token、设备标识或
日志原文；本项目的日志脱敏是启发式的，仍可能漏掉自定义格式的密钥。

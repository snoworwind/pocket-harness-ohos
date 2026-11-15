# @deepseek-ai/dsh-harmony-compat

DeepSeek Harness 0.2.2-rc.1 的鸿蒙适配插件（Host 半 + Web Client 半）。
第一版只提供一个开关：**鸿蒙适配 / 后台保活**（`keepAlive`，默认 `true`）。

这个开关本身不执行任何保活动作。Host 半只负责把当前值镜像到
`$DSH_HOME/harmony-native.json`；HarmonyOS 应用（`entry/src/main/ets/pages/Index.ets`）
每 3 秒读一次该文件，值变化时启停后台定位连续任务
（`entry/src/main/ets/platform/NativeRuntime.ets` 的 `readKeepAlive()`，文件缺失按 `true` 处理）。

## 文件镜像

| 项 | 值 |
| --- | --- |
| 路径 | `$DSH_HOME/harmony-native.json`（应用里是 `filesDir/harness-home/harmony-native.json`） |
| 内容 | `{"keepAlive":true}` / `{"keepAlive":false}`，单行 JSON，无其它字段 |
| 时机 | 插件挂载时写一次；之后每次 Loader 提交该字段的新值都重写 |
| 原子性 | 先写同目录 `<file>.<pid>.tmp`，再 `rename` 覆盖目标文件 |
| 失败 | 仅 `ctx.logger.warn`，不阻塞设置写入 |

Host 用 `@deepseek-ai/dsh-home-paths` 的 `dshHomePath()` 解析 home：
`$DSH_HOME`（空/全空白视为未设置）优先，否则 `~/.dsh`。

## 设置如何注册（与最初设想的差异）

0.2.2-rc.1 **没有** `settings.register(namespace, schema)` 这样的 API。真实实现是：

- `@deepseek-ai/dsh-settings` 的 `SettingsForms.describe()` 遍历当前 profile 的每个
  活动 entry，取 `entry.fiber.runtime.Config` 里带 `.volatile()` 的字段投影成表单；
- 命名空间就是 `entry.options.id`（`@deepseek-ai/dsh-settings/lib/index.js:436-451`）；
- 只有带 `.volatile()` 的字段会出现在表单里（`volatileForm()`，同文件 `:122-131`），
  解析后该字段变成一个冻结的 `{ get() }` 引用（schemastery `lib/index.mjs:235-238`、`:265-275`；
  cosmokit `lib/index.js:102-109`）；
- 值变化由 Loader 原地提交并 `emit("loader/volatile-update", paths)`
  （`@deepseek-ai/cordis-plugin-loader/lib/index.js:523-556`，事件在 `:553`）。

因此：

- Host 的 `Config = z.object({ keepAlive: z.boolean().default(true).volatile() })`；
- **profile entry id 必须叫 `harmony-native`**，命名空间才会是 `harmony-native`；
- Client 用 `ctx.configForms.get("harmony-native")`、`form.set("keepAlive", value)`。

这正是 `cordis.patch.yml` 里 id 用 `harmony-native`（而不是任务书初稿里的
`harmony-compat`）的原因：包名仍是 `@deepseek-ai/dsh-harmony-compat`，但 entry id
与 settings 命名空间是同一个字符串，无法分开命名。如果确实需要 entry id 为
`harmony-compat`，把 `cordis.patch.yml` 的 id 和 `lib/client.js` 里的
`namespace` 常量一起改掉即可，两边必须一致。

Host 还调用了 `settings.configure({ auto: false }, ctx.fiber)`，避免设置页同时
再生成一份自动配置页（与 `dsh-client-locale`、`dsh-client-ui-settings` 的 Host 半一致）。

## 激活方式

```bash
dsh --profile web --patch <engine-archive>/patches/harmony-compat.cordis.patch.yml
```

`cordis.patch.yml` 只有一条 `- insert:`：

```yaml
- insert:
    - id: harmony-native
      name: '@deepseek-ai/dsh-harmony-compat'
```

### 打包时必须满足的两个前提

1. **包能被裸包名解析到。** Loader 在 profile 层用包名 import 该 entry；仅把目录拷进
   `engine/node_modules/@deepseek-ai/dsh-harmony-compat/` 还不够，因为 profile 的模块
   解析不会向上走到引擎目录。两条可用路径：
   - **装进 profile（不改引擎文件，推荐）**：在
     `$DSH_HOME/profiles/web/package.json` 的依赖里登记该包，并让
     `$DSH_HOME/profiles/web/node_modules/@deepseek-ai/dsh-harmony-compat` 指向包目录
     （复制或符号链接）。`dsh-app-boot` 会把 profile 直接依赖里已安装的包纳入
     profile scope 的解析表。
   - **纳入安装闭包（打包期编辑引擎清单）**：把该包加进 dsh 安装包
     （`engine/node_modules/@deepseek-ai/dsh/package.json`）的 `dependencies`，使
     `collectInstallationScopePackages()` 把它放进 installation scope。

   若两者都不方便，可把 patch 的 `name:` 改成插件入口的绝对路径
   （`.../dsh-harmony-compat/lib/index.js`）；`dsh-client-modules` 对路径形式也会
   从模块位置向上找最近的 `package.json`，客户端半边通常仍能被发现，但裸包名更稳。
2. **客户端半边随 entry 一起被发现。** `dsh-client-modules` 扫描活动 entry 的包清单，
   读取 `dsh.client.platform === "web"` 和 `exports["./client"]`，把
   `lib/client.js` 作为 `/plugins/@deepseek-ai/dsh-harmony-compat/client.js`
   提供给浏览器（资源 id 是包名，不是 profile entry id）。

`dsh.client.inject` 声明了 `@deepseek-ai/dsh-client-locale`、`@deepseek-ai/dsh-client-ui-settings`、
`@deepseek-ai/dsh-client-ui-settings-general`，保证 `locale`/`configForms` 服务与
`settings.general.item` 槽位在本模块之前就绪（`ctx.slots.inject` 本身也会等槽位声明）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `package.json` | ESM 包清单；`exports["./client"]` + `dsh.client` |
| `cordis.patch.yml` | profile 插入行 |
| `lib/index.js` | Host：`Config`、`loader/volatile-update` 监听、原子镜像 |
| `lib/client.js` | 浏览器模块：locale 字典、`settings.general.item` 行、`Switch` |

## 验证

```bash
node --check lib/index.js
node --check lib/client.js
```

浏览器端只能在真实 Web UI 里验证：设置 → 通用应出现两行文案与一个 `Switch`；
切换后 `$DSH_HOME/harmony-native.json` 内容跟随变化，应用轮询后启停后台任务。

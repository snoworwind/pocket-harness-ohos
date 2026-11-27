# 应用内浏览器（实验性，未真机验收）

此原型使用独立 ArkWeb 组件，不复用 DSH 主界面的 controller，也不向网页注册 DSH 下载、上传或终端桥。浏览器网页及其内容均不可信。侧栏 console/nonce 消息仅供面板状态和当前会话标签同步，不能作为控制权限的认证机制。

## 界面与唤起

浏览器面板由 ArkWeb 原生承载，外观跟随应用明暗主题：地址栏、进度条、页面标题、Agent 连接状态和“刷新/关闭”都在同一块面板内；未打开页面时显示空状态，而不是一块白底。网页未提供深色样式时，深色主题启用 ArkWeb 的强制深色算法，避免网页白底与深色侧栏割裂。

Agent 首次调用浏览器工具时，如果中继尚未启动，插件只在私有目录写入一个 `launch-request.json`（仅含会话标签、随机 id 和 20 秒期限），不会传 URL、凭据或授权信息。壳层轮询到请求后校验文件类型、大小、会话和期限，创建隐藏的浏览器实例并启动中继；**不会自动展开右侧栏**。用户自己打开右侧栏后，页面插件才选中已有的“共享浏览器”tab，看到的就是 Agent 正在操作的同一个 ArkWeb 实例和页面，不会重新加载。关闭 tab、切换会话或应用进入后台会停止中继；仅收起侧栏不会销毁页面。

## 实验性 Agent 控制

代码提供 11 个浏览器工具（`open`/`observe`/`text`/`scroll`/`click`/`hover`/`fill`/`type`/`press`/`select`/`navigate`）。工具默认注册，可在 `harmony-native.json` 中设置 `browserAgent: false` 禁用。Agent 首次使用时请求创建浏览器实例，但不展开侧栏；用户打开侧栏后看到同一个实例。只读/工作区修改模式下每次操作应出现原生确认；自动审查或完全权限模式按下述策略处理。`about:blank` 仅可用于请求打开网页，不可用于观察。关闭浏览器、切换会话或应用进入后台时控制会停止；仅收起侧栏不会销毁页面。**此自动唤起与隐藏期间运行的流程尚未完成设备端端到端验证。**

`browser_observe` 经逐次授权后返回标题、地址以及有限的页面文本和控件标签；不主动读取输入框、可编辑区域的当前值或 Cookie，也不遍历 iframe、shadow DOM。可见性判断只是尽力而为，不保证排除所有敏感信息或隐藏内容。长快照会在完整条目边界截断并标记；工具输出还设有独立长度上限。网页内容以随机边界标记为不可信数据，不能作为指令。`browser_open` 只提交导航，不表示页面已加载完；提交后桥会拒绝后续操作，直到用户在页面开始与结束事件后，点击原生“确认当前页面并恢复”，且页面、会话和可见性检查通过。页面结束不表示网络稳定；ArkWeb 事件没有可靠导航 ID，同 URL 的过时事件和后续 SPA 变化仍不能完全排除。每次后续操作仍需单独授权。`browser_scroll` 每次只能经原生授权上下滚动 400 vp，不接受任意脚本或坐标；返回仅表示调用已提交，不保证实际移动或网络安静。滚动可能触发页面脚本、懒加载和网络请求，随后观察仍需逐次授权。

`browser_click` 只能点击**上一次 `browser_observe` 快照给出的元素引用**（形如 `e3`）。快照会为带盒子的可交互元素（`a`/`button`/`input`/`textarea`/`select`）分配有界引用（`e0`–`e79`），链接与按钮还带可见文本 `caption`，便于 Agent 选择目标；引用只对产生它的那次快照有效：页面变化后必须重新观察，否则操作会因引用失效而被拒绝。执行的是固定程序，只把校验过的整数下标代入，绝不拼接网页或 Agent 文本；脚本会拒绝不在文档中、已禁用、无布局盒或 `display:none`/`visibility:hidden` 的元素，并检查元素中心点是否位于视口内、是否被其他元素覆盖（`offscreen`/`covered`，借鉴 agent-browser 的“失败而不是假成功”）。返回 `Click dispatched` 仅表示点击已派发，不表示页面已响应、未跳转或已稳定；点击可能触发导航、表单提交和任意页面脚本，因此每次点击都需要单独授权。发生断连或超时时，已发起操作的状态可能未知，不能自动重试。

中继由壳层在浏览器实例可用时启动，以独立 Node 进程运行，仅接受具备随机凭据的 loopback 连接；凭据通过应用私有目录交付，不经网页桥或 HTTP。该机制不隔离同 UID 的命令或插件。会话 ID 来自主 GUI 的可见状态，只是供用户核对的标签，不是独立鉴权；会话变更检测有轮询延迟。授权前后比较页面代数、标题和地址，但不能排除页面内部状态变化或变化后恢复。

## 隔离与限制

**浏览器当前是全局共享实例，不按 DSH 会话隔离**：不同会话的浏览器 tab 可能看到同一个页面，关闭其中一个可能关闭共享页面。不要在预期会话隔离的场景中使用；页面登录状态也可能被其他会话看到。

顶层导航限制 HTTP(S) 不等于网络隔离：页面仍可能访问本机、内网或加载子资源。独立 controller 也不能证明 Cookie 存储隔离。弹窗、权限、下载、重定向、存储、私有凭据权限、profile 依赖解析及设备生命周期均需真机验证。网页内容不能当作 Agent 指令。

## 可用操作

| 工具 | 参数 | 语义 |
| --- | --- | --- |
| `browser_open` | `url` | 提交导航；需用户点“确认当前页面并恢复”后才能继续 |
| `browser_observe` | 无 | 只读快照：标题、地址、文本与带 `ref` 的控件 |
| `browser_text` | `offset`, `limit` | 只读正文提取（默认 0/4000，上限 8000），可翻页；不含表单值与隐藏内容 |
| `browser_scroll` | `direction: up/down` | 原生滚动 400 vp |
| `browser_click` | `ref` | 点击；视口外会先滚动到元素再点，被遮挡、隐藏或禁用会失败而不是假成功 |
| `browser_hover` | `ref` | 在元素中心派发 `mouseover`/`mouseenter`/`mousemove`，展开悬停菜单后需重新快照 |
| `browser_fill` | `ref`, `text` | 清空后填入（原生 setter + `input`/`change` 事件） |
| `browser_type` | `ref`, `text` | 追加输入，不清空原值 |
| `browser_press` | `key` | 白名单按键；Enter 在表单控件上会额外请求提交 |
| `browser_select` | `ref`, `value` | 按 value 或精确可见 label 选择原生 `<select>` 选项 |
| `browser_navigate` | `action: back/forward/refresh` | 原生历史导航/刷新，使所有引用失效 |

每个操作都需要独立的原生授权；`auto` 与 `danger-full-access` 预设只跳过确认面板，不跳过页面、会话、代数和参数绑定检查。

**文本输入的安全通道**：文本在插件侧编码为 base64 后随中继帧传输，页面程序固定，只在标记位置代入有界整数下标、base64 字面量与枚举词；网页或 Agent 文本从不作为脚本源码拼接。文本上限 512 字符，拒绝控制字符（换行与制表除外）。授权载荷只携带**文本字节长度**，不携带内容，因此密码等敏感输入不会进入审批 UI 或日志。

**可编辑性判定**（借鉴 agent-browser 的 `not_editable`/`read_only`/`disabled` 语义）：`select`、`option`、按钮、`checkbox`/`radio`/`file`/`hidden`/`image`/`button`/`submit`/`reset`/`range`/`color`/日期时间类 input 一律拒绝；`readonly` 与 `disabled` 字段拒绝；拒绝时不修改任何字段值。

**输入后回读**：填入后重新读取字段。一致返回 `Field filled` / `Text appended`；被 `maxlength` 等截断返回 `truncated`；被页面脚本（如输入掩码）改写返回 `rewritten`。回读只产生状态词，**不回显字段内容**。这些结果只代表读回那一刻，页面之后仍可能改写或跳转。

`browser_press` 派发的是合成键盘事件，**不触发浏览器默认行为**；Enter 在属于表单的控件上会额外调用 `form.requestSubmit()`，可能提交表单并跳转，因此同样需要逐次授权。`browser_select` 只支持原生 `<select>`：自定义 ARIA 下拉（Radix、Headless UI 等）请先 `browser_click` 打开再点击选项。value 与 label 同时命中不同选项、或同一 label 对应多个选项时返回 `ambiguous`。

**快照截断**：一次快照最多 80 个可交互元素 / 4000 个节点 / 24 KB JSON。任一上限触及时返回 `truncated: true`，并在结果后附一句提示——避免把局部视图误当成整页。真实网页常常超过 80 个控件，此时应先滚动或缩小范围再观察。

`browser_hover` 只派发合成指针事件，**不移动真实光标**：依赖真实 `mousemove` 坐标的页面（部分富文本编辑器、地图）只能部分生效；返回的 `Hover dispatched` 不代表菜单已展开，需要重新 `browser_observe` 确认。

`browser_text` 与 `browser_observe` 走同一套可见性判断：`display:none`、`visibility:hidden`、`opacity:0`、`aria-hidden`、`script`/`style`、可编辑子树都不会进入结果。长文章用 `offset` 翻页，返回的 `total` 是完整字符数，`truncated` 表示还有后续。

截图、按坐标点击、任意脚本执行、文件上传、拖拽与双击仍未实现。真机验证见 [BROWSER-VERIFY.md](BROWSER-VERIFY.md)。



浏览器操作是否跳过原生确认，由**发起操作的 DSH 会话当前权限预设**决定，每次调用实时读取：

| 当前会话预设 | 浏览器操作 |
| --- | --- |
| `auto`（自动审查） | 自动放行，不再弹浏览器确认 |
| `danger-full-access`（完全权限） | 自动放行，不再弹浏览器确认 |
| `read-only`、`workspace-write`、`custom` 或读取失败 | 必须由用户在原生面板逐次确认 |

自动放行**只跳过浏览器自己的确认面板**，不跳过页面、会话、可见性和代数绑定检查；`browser_open` 之后仍然需要用户点击“确认当前页面并恢复”。自动模式下 `auto` 预设的工具调用仍会先经过 DSH 的 `tools/pre-execute` 自动审查，审查拒绝时由 DSH 自己的审批流程处理。

判定规则（`plugins/dsh-harmony-browser/index.js`）刻意保守：

- 预设只从实时 `permissionPresets.current(agent.session)` 读取，绝不接受工具参数、网页或 GUI 自报的模式。
- 初次读取如果不是 `auto`/`danger-full-access`，本次调用后续即使切到自动模式也仍需确认——该调用没有经过自动审查。
- 自动路径会在执行前再查一次，预设变化即降级为人工确认。
- 服务缺失、抛错或返回未知值一律按人工确认处理。

在预设之上还有一层**策略分类**（`plugins/dsh-harmony-browser/policy.js`，借鉴 Codex 的三态决策），对每个已校验的请求先归入 `allow`/`prompt`/`forbid`：

| 操作 | 影响 | 无危险参数时 |
| --- | --- | --- |
| `browser_observe`、`browser_text`、`browser_scroll` | 只读 | `allow`（隔离实例内不改变页面或外部状态） |
| `browser_fill`、`browser_type`、`browser_select` | 改变表单状态 | `prompt` |
| `browser_click`、`browser_hover`、`browser_press`、`browser_navigate`、`browser_open` | 可能导航/提交/触发页面脚本 | `prompt` |

危险请求（非 `http(s)`、带凭据的 URL、缺失或畸形的编码文本/键/引用）**在任何预设下都不会被静默放行**：`danger-full-access` 最多降为 `prompt`，其余预设直接 `forbid` 并返回具体原因（例如 `scheme file: is not allowed (only http/https)`）。策略判定发生在取凭据和连接中继之前，拒绝不会产生任何网络或页面副作用。

这减少了但**不能消除**跨进程竞态：权限读取与原生执行之间仍有窗口，页面内 JS 也可能在滚动的同一时刻改变状态。会话切换会让整个桥停止。

## 审计留痕

每次请求产生一行 JSONL，写在 `$DSH_HOME/browser-audit.jsonl`（目录 0700、文件 0600），可用 `DSH_BROWSER_AUDIT=0` 关闭：

- 记录：时间、操作、策略决策（`allow`/`prompt`/`forbid`）及原因、结果（`ok`/`error`/`unknown`/`forbid`）、元素引用、滚动方向、导航动作、文本窗口、输入字节长度；
- 对 URL 只记录 **scheme 与 hostname**，路径与查询串（可能含 token）一律丢弃；
- 绝不记录页面内容、输入文本、凭据或会话标识；
- 单个文件超过 512 KB 时轮转为 `browser-audit.jsonl.1`（覆盖上一份），磁盘占用上限约 1 MB；
- 写入失败被吞掉，不影响请求。

## 参考的开源设计

- [Vercel agent-browser](https://github.com/vercel-labs/agent-browser)：参考其先观察再操作、页面变化后刷新快照的交互模型，以及[不可信内容边界和输出上限](https://agent-browser.dev/security)。本项目的随机边界是纵深防御，不保证阻止提示注入。
- [NexoAgent 浏览器快照](https://github.com/NexoBridge/NexoAgent/blob/b3ca6056d3b70fdb2768d2956e92c42ce745bf15/electron/server/browser-ax.ts)：参考页面生命周期与快照绑定的设计。其实现依赖 Electron/CDP，不能直接用于 ArkWeb；其中可能返回的表单值不应照搬。
- [Browser Use 可见性与交互实现](https://github.com/browser-use/browser-use/blob/main/browser_use/ax.py)：参考 `display: contents` 元素无自身盒子但其文本可能可见的处理；该项目的 CDP 交互与自动接受对话框策略未在此照搬。
- [OpenAI Codex 审批与沙箱策略](https://github.com/openai/codex)：参考 `codex-rs/core/src/safety.rs` 的 `SafetyCheck`（`AutoApprove`/`AskUser`/`Reject{reason}`）三态与 `codex-rs/core/src/exec_policy.rs` 的 `Decision`（`Allow`/`Prompt`/`Forbidden`）决策矩阵。据此新增 `policy.js`：危险请求在任何预设下都不会被静默放行（`danger-full-access` 最多降为 `Prompt`，其余一律 `Forbid`），且拒绝带有具体原因。只读操作在隔离实例内归为 `Allow`，会改变页面或对外产生副作用的操作归为 `Prompt`。Codex 的进程级沙箱（bwrap/Seatbelt）无法直接用于 ArkWeb，本项目的隔离依靠独立 Web 实例、loopback 绑定与逐操作原生确认。

以上为设计参考，并未将这些项目的源码复制进本项目。

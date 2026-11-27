# Agent 浏览器真机验证清单

Node 侧 217 项测试只覆盖协议与固定脚本的语义，**不能替代 ArkWeb 真机行为**。以下清单用于在设备上逐项确认。

## 0. 构建与安装

1. DevEco Studio 打开工程，确认 SDK 与设备 API 版本匹配。
2. 构建：
   ```bash
   hvigorw --mode module -p product=default assembleHap
   ```
3. 安装（未签名包按 debug 构建）：
   ```bash
   hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
   ```
4. 打开开关：设置 → 实验性功能 → Agent 浏览器（`browserAgent=true`）。
5. 确认权限预设：先用 `read-only` 验证"每次都弹确认"，再用 `auto` 验证跳过面板。

## 1. 冒烟流程（10 分钟）

按顺序执行，任一步失败即停止并记录：

| 步骤 | 操作 | 期望 |
| --- | --- | --- |
| 1 | `browser_open` 到一个简单页面 | 弹确认面板；确认后页面加载；需再点"确认当前页面并恢复" |
| 2 | `browser_observe` | 返回标题、URL、带 `e0…` 引用的控件与可见文本 |
| 3 | `browser_text` | 返回正文文本，`total` 大于 `limit` 时带截断提示 |
| 4 | `browser_scroll` 下滚 | 页面实际滚动 |
| 5 | `browser_click` 一个链接 | 返回 `Click dispatched`；页面跳转后旧引用失效 |
| 6 | `browser_navigate` back | 返回上一页，并要求重新观察 |

## 2. 逐工具检查

- **browser_observe**：长页面超过 80 个控件时返回 `truncated: true`；隐藏元素、`aria-hidden`、`display:none` 不出现；输入框的**值**不出现。
- **browser_text**：正文按文档顺序；表单值、`script`/`style`、隐藏区域不出现；`offset` 翻页衔接无重复无丢失。
- **browser_fill / browser_type**：在 React/Vue 受控输入框里能写入；`maxlength` 截断返回 `truncated`；输入掩码改写返回 `rewritten`；回读**不回显内容**。
- **browser_press**：Enter 在表单里触发提交（返回 `submitted`）；Tab 移动焦点。
- **browser_select**：按 value 与按 label 都能选中；歧义时返回 `ambiguous`。
- **browser_hover**：在带下拉菜单的站点上悬停后重新 observe，菜单项出现（若未出现，记录站点名——合成 hover 不移动真实光标）。
- **browser_click**：元素在视口外时自动滚动后点击成功；被浮层遮挡时返回 `covered` 而不是假成功。
- **browser_navigate**：back/forward/refresh 均生效；导航后旧 `ref` 一律 `stale`。

## 3. 安全与失败路径

- `browser_open` 传 `file://`、`javascript:`、带用户名密码的 URL → 被拒，且**不发起任何网络请求**。
- `browser_fill` 传 600 字符 → 被拒。
- 导航后立刻点击旧 `ref` → `stale`。
- 打开原生确认面板，检查面板上**没有**输入文本内容（只有元素标签与文本长度）。
- 用 `auto` 预设执行 `browser_open` 到危险 URL → 仍被策略层拒绝（`danger-full-access` 也只是要求确认）。
- 断网或杀掉 relay 进程 → 返回 `UNKNOWN`，且不自动重试。

## 4. 必须在真机确认的风险点

这些是 Node 模拟无法覆盖的，逐条记录实际结果：

1. `loadWithNamedRef` 在当前 ArkWeb 版本是否可用、是否按预期隔离会话。
2. 原生 value setter（`HTMLInputElement.prototype` 的 `value` 描述符）在 ArkWeb 内核是否与 Chromium 一致——受控组件能否收到 `input` 事件。
3. `scrollIntoView({block:'center'})` 在 ArkWeb 的滚动行为与同步性。
4. 合成 `MouseEvent('mouseenter')` 是否触发常见前端框架的悬停逻辑。
5. `document.elementFromPoint` 在缩放/`devicePixelRatio` 非 1 时返回的元素是否准确。
6. 页面在 `runJavaScript` 执行期间发生导航时的返回值与异常形态。

## 5. 失败排查

```bash
# 应用日志
hdc shell hilog | grep -iE 'browser|relay'
# 中继进程
hdc shell ps -ef | grep relay
```

常见原因：

- **relay 未启动**：`browserAgent` 开关未开，或启动时被权限预设拒绝。
- **每次操作都失败**：会话不可见（切到后台），`visibleSessionId` 不匹配。
- **引用一直 stale**：页面有定时刷新或 SPA 重渲染，需要在操作前立即 observe。
- **输入不生效**：目标不是原生 `<input>`/`<textarea>`（自定义富文本需先 click 聚焦）。

## 6. 验证记录模板

| 项 | 设备/系统 | 结果 | 备注 |
| --- | --- | --- | --- |
| open | | | |
| observe 截断 | | | |
| text 翻页 | | | |
| fill 受控组件 | | | |
| hover 菜单 | | | |
| click 自动滚动 | | | |
| 危险 URL 拒绝 | | | |
| 审批不含文本 | | | |

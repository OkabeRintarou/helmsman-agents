# 09 · Web 界面（LiveView）

> 对应 bosun 的 06、07。bosun 是 React SPA + 15 秒轮询；Helmsman 用 LiveView，靠 PubSub 实时推送（任务、运行的执行记录、机器在线状态），没有单独的前端工程和 REST 层。

## 1. 路由

| 路径 | LiveView | 说明 |
|---|---|---|
| `/users/*` | phx.gen.auth 生成 | 登录、注册、设置 |
| `/invite/:token` | `InvitationLive` | 接受邀请 |
| `/` | — | 跳到最近访问的工作区；没有就进 `/workspaces/new` |
| `/w/:slug` | `DashboardLive` | 指派给我（含我名下 Agent）的任务、待回答的提问、正在跑的运行、最近合并、在线的机器 |
| `/w/:slug/projects` | `ProjectLive.Index` | 项目卡片 |
| `/w/:slug/p/:key` | `TaskLive.Index` | 任务列表：状态多选、标签、执行方、搜索框，全部同步到 URL query |
| `/w/:slug/t/:ident` | `TaskLive.Show` | 任务详情 |
| `/w/:slug/query` | `QueryLive` | BQL 编辑、结果表、保存筛选器 |
| `/w/:slug/agents`、`/w/:slug/agents/:name` | `AgentLive.Index` / `.Show` | Agent 列表、配置、运行与用量（12 §5） |
| `/w/:slug/runs/:id` | `RunLive.Show` | 单次运行的完整执行记录（任务页里的弹窗也能看，这里便于分享链接） |
| `/w/:slug/squads` | `SquadLive.Index` | 小队（16 §3） |
| `/w/:slug/autopilots`、`/w/:slug/autopilots/:id` | `AutopilotLive.*` | 自动化（16 §3） |
| `/w/:slug/settings` | `SettingsLive.General` | 常规：工作区名称、slug（owner）、退出工作区；设置的第一个标签，侧栏「设置」指向这里 |
| `/w/:slug/settings/members` | `SettingsLive.Members` | 成员、角色、邀请 |
| `/w/:slug/settings/tokens` | `SettingsLive.Tokens` | API Token（03 §3） |
| `/w/:slug/settings/runtimes` | `SettingsLive.Runtimes` | 我的机器与运行时（12 §5） |
| `/w/:slug/settings/github` | `SettingsLive.GitHub` | 连接 GitHub、仓库列表（15 §1） |
| `/w/:slug/settings/data` | `SettingsLive.Data` | 导出 / 导入（11） |
| `/device` | `DeviceLive` | 守护进程登录时输入设备码并确认（12 §3.1） |
| `/admin/github` | `Admin.GitHubLive` | 实例管理员创建 GitHub App（15 §1） |

`live_session :workspace, on_mount: [{UserAuth, :require_authenticated}, {UserAuth, :require_workspace}]`，进入时把 `%Scope{}` 放进 `socket.assigns.current_scope`。

## 2. 布局

- 左侧栏：工作区切换、搜索入口（打开命令面板）、新建任务、项目列表、保存的筛选器、设置，底部是当前用户菜单；不设全局顶栏，每页用页头（标题 + 页面操作）。全局搜索由命令面板承担：按 `KEY-N` 直接跳转，M10 起显示命中的任务与 Feedback 片段（`add-web-ui-foundation` DR-3）。
- 组件放在 `HelmsmanWeb.Components.*`：`status_badge`、`actor_chip`、`task_id_link`、`relative_time`、`markdown`、`side_panel`、`confirm_dialog`。
- 沿用 bosun 的界面约定：**需要输入的弹出层一律用右侧面板**（新建任务 / 项目、写 / 修订 Feedback、打回 / 拒绝 / 撤销填原因、筛选器）；纯确认用确认对话框；不用浏览器原生 `confirm`。

## 3. 任务详情页

```
┌ BOS-12  标题（点击编辑）       [被阻塞] [待回答] [keel/dev 正在处理]    状态徽章  [开始] [完成] … ┐
│ 左栏                                              │ 右栏                                     │
│  描述（渲染 ↔ 编辑）                                │  优先级 / 标签 / 执行方 / 提出方            │
│  Feedback 线索（作废版本折叠；修订自 #n 锚点互跳）     │  运行：进行中 / 历史（停止、重试、执行记录）  │
│  [添加 Feedback]（@ 自动补全；「同时发给正在运行的 │  PR：#123 状态、CI、合并进度                 │
│   keel/dev」勾选框）                               │  Epic：标题 + 进度条 / 步骤列表             │
│                                                   │  关联：依赖 / 被依赖 / 替代 / 被替代（🔒）    │
│                                                   │  历史时间线（commits、tests、auto 标记）     │
└───────────────────────────────────────────────────┴──────────────────────────────────────────┘
```

- **迁移按钮**只显示 `StateMachine.allowed(status)` 里的、且当前角色有权限的；被阻塞时「开始」禁用并在 tooltip 里列出阻塞任务。
- 「完成」「验收」打开**完成证据面板**：提交 hash、测试命令 / 是否通过 / 摘要、备注；自验收时提示最近一次 → DONE 有没有通过的测试。
  有 PR 时，「验收」面板显示 PR 的 CI 状态、本次验收对应的提交，以及按合并策略**验收后会发生什么**（「CI 通过后自动合并到 main」/「你不独立于这份代码的出处，不会自动合并」/「需要人在 GitHub 上合并」）。有运行正在进行时「验收」禁用，提示等运行结束（05 §2）。
  PR 卡片在 `merge_status = stale` 时提供「按当前提交重新验收」，`blocked` 时显示原因和 GitHub 链接（15 §4）。
- 打回 / 重开 / 拒绝 / 重新提交 / 撤销：面板要求填原因，原因作为 Feedback 写入（撤销为 `comment`，其余为 `review`），事件引用它（05 §3 第 5 步）。执行方是托管 Agent 时，面板提示「将触发 keel/dev 按此意见修改」。
- **指派**：选择器里人、Agent、小队分组；选托管 Agent 或小队时弹出确认：「开始」或「暂不开始」（13 §2）；无权触发的置灰并说明原因；运行时离线时提示会排队等待。
- **运行卡片**：每条显示触发原因、Agent、状态、耗时、用量；点开是实时滚动的执行记录（文本、工具调用、工具输出折叠显示）。
- 字段编辑带 `lock_version`；收到 `{:error, :stale}` 时提示「已被 X 修改」并重新加载，保留用户输入的草稿。

## 4. Markdown 与 Mermaid

- 渲染：服务端 `MDEx.to_html!/2`，开 GFM 扩展（表格、任务列表、删除线、自动链接、脚注），启用 ammonia 净化（Agent 写的内容不可信）。代码高亮用 MDEx 内置的 lumis。
- 不做缓存：MDEx 是 Rust 实现，渲染一张单的全部内容在毫秒级。真成为瓶颈再按 `(id, updated_at)` 加 ETS 缓存。
- Mermaid：渲染结果里的 ` ```mermaid ` 代码块输出为 `<pre class="mermaid" phx-hook="Mermaid">`，前端 hook 懒加载 `mermaid` 包渲染；主题跟随明暗模式。
- `#BOS-12`、`BOS-12#3` 这类引用在渲染时转成链接（只转本工作区里存在的）。
- 编辑器：textarea + 「预览」切换（预览走同一个渲染函数），粘贴 / 快捷键用一个小 hook 实现。不引入 Milkdown 这类富文本编辑器——LiveView 与重型 JS 编辑器的状态同步代价大，Markdown 源码编辑对人和 Agent 都够用。以后需要再用 `phx-update="ignore"` 包一个。

## 5. 实时

| 主题 | 谁订阅 | 收到后 |
|---|---|---|
| `project:<id>` | `TaskLive.Index` | 用 `stream_insert` 更新那一行；不在当前筛选条件里的行移除 |
| `task:<id>` | `TaskLive.Show` | 重新加载详情；用户正在编辑的字段不覆盖，只提示「有更新」 |
| `workspace:<id>` | 外壳（`Shell.on_mount`，每个 `/w/:slug` 页面一份），页面不得再自行订阅 | 外壳处理工作区改名 / 改 slug；其余消息（项目增减、成员变化、待回答数量等）交给页面的 `handle_info/2`，如 `DashboardLive`、侧栏、设置页 |
| `workspace:<id>:agents`（Presence） | `DashboardLive`、`AgentLive.Index` | 在线的外接 Agent |
| `workspace:<id>:runs` | `DashboardLive`、`AgentLive.*`、侧栏 | Agent 忙闲、队列长度（13 §9） |
| `workspace:<id>:runtimes` | `RuntimesLive`、`AgentLive.*` | 机器上线 / 离线 |
| `run:<id>` | 运行记录弹窗、`RunLive.Show` | 追加执行事件；事件很多时只保留最近 500 条在页面上，更早的按需加载 |
| `user:<id>` | 根布局 | 被移出工作区 / 角色变化 → 重新挂载 |

列表页用 LiveView streams，不在 socket 里保存整张表；分页用「加载更多」。执行记录同样用 streams。

**消息处理约定**：一个主题上有多种消息，页面只写自己关心的 `handle_info/2` 子句。`HelmsmanWeb.live_view/0` 为所有 LiveView 加 `@before_compile HelmsmanWeb.LiveFallback`：模块定义了 `handle_info/2` 且没有自有兜底（第一个参数为裸变量、无 guard 的子句）时，在其子句之后追加一个忽略其余消息的子句（`Logger.debug` 记一行）；页面已有自有兜底时不追加，自有兜底须对未处理的消息返回 `{:noreply, socket}`；没定义时由外壳 `:halt`。都不捕获页面子句里的异常（`add-workspace-settings-ui` DR-2）。

## 6. 测试

- `Phoenix.LiveViewTest`：每个页面的渲染、表单校验、迁移按钮按权限显示。
- 实时：一个测试里开两个 LiveView（或一个 LiveView + 直接调领域函数模拟 Agent），断言另一端收到更新；执行记录用假守护进程推事件验证。
- JS hook 只有这几个：Mermaid、编辑器（含 @ 补全）、执行记录滚动，以及外壳用的 `Hotkeys`、`Copy`、`LocalTime`（`add-web-ui-foundation` DR-4）；每个约 100 行以内，只属于单个组件的用 colocated hook。外壳与通用 hook 不引入 npm 包；**Mermaid 是唯一例外**：使用 npm 包 `mermaid`（在 `assets/package.json` 固定版本），由构建打包进本站静态资源并按需懒加载——不进主 bundle、不走 CDN，符合 11 §3 只放行自身的 CSP；具体打包方式由 Feedback 界面变更决定。手工验收即可。

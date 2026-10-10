# 03 · Actor、Agent 与 API Token

> 对应 bosun 的 11（身份与操作者）。bosun 里名字是自报的；Helmsman 有了认证，名字背后一定有一个真实用户负责。

## 1. Actor

Actor = 所有会出现在记录里的身份：任务的提出方 `created_by`、执行方 `assignee`、历史条目的操作者、Feedback 作者。

| kind | 来源 | 名字 | 说明 |
|---|---|---|---|
| `human` | 用户加入工作区时自动创建，每个用户每个工作区一个 | 缺省取邮箱前缀，可改，如 `alice` | 浏览器里的一切操作都记在它名下 |
| `agent` | **托管**：用户在 Agent 页面创建并配置（12）；**外接**：Agent 在 MCP 里 `identify` 时创建 | 约定 `<项目key>/<用途或 worktree>`，如 `keel/dev`、`keel/reviewer` | 必须有所属用户 `owner_id` |
| `squad` | 建小队时创建（16 §1） | 如 `backend-team` | 只能被指派、被 @，不会成为作者 |
| `system` | 每个工作区一个，名为 `helmsman` | 固定 | 服务端自动动作的署名：CI 失败自动重开、防循环备注等（15 §5、13 §7） |

- 名字在工作区内唯一（不区分大小写），规则 `^[a-z0-9][a-z0-9._/-]{0,63}$`；`helmsman` 保留。
- 界面上统一用 `ActorChip`：人形 / 机器人 / 小队 / 系统图标 + 名字；Agent 的 tooltip 显示所属用户和托管 / 外接。
- 停用（`disabled_at`）后不能再写，历史保留。

**为什么 Agent 要按 worktree 区分**：自验收规则（05 §5）按 actor 判断「是不是执行方本人」。同一个用户在两个 worktree 里跑的 Agent 如果共用一个名字，就分不清谁做的、谁验收的。

## 2. API Token

| 项 | 规则 |
|---|---|
| 格式 | `hm_` + 32 字节随机数的 base32；只在创建时显示一次 |
| 存储 | 只存 SHA-256（`token_hash`）和前 8 位 `prefix`（列表里识别用） |
| 归属 | 一个用户 + 一个工作区 |
| scopes | `mcp`、`api:read`、`api:write` |
| `default_agent_id` | 可选：这个 Token 缺省以哪个 Agent 的身份写入（推荐每个 worktree 一个 Token） |
| 过期 / 吊销 | `expires_at` 可选；`revoked_at` 即时生效 |
| `last_used_at` | 最多每分钟更新一次，避免每个请求都写库 |

viewer 不能创建 Token（只读的 Token 价值不大，以后需要再放开）。

`hm_` 是给人和外接 Agent 用的。守护进程用的 `hmd_`、托管 Agent 运行中用的 `hmr_` 见 12 §4。

## 3. 在界面里管理

`/w/:slug/settings/tokens`：

- 「我的 Token」：名称、前缀、scopes、默认 Agent、最近使用、过期；新建（创建后弹出一次明文 + 一段可复制的 `claude mcp add …` 命令）/ 吊销。
- admin 以上额外看到全工作区的 Token，可以吊销。

Agent（托管与外接）统一在 `/w/:slug/agents` 管理（12 §5）。

## 4. 身份解析

**托管 Agent 运行中**（`hmr_` 令牌）：身份固定为这次运行的 Agent，下表不适用——`identify` 直接返回当前身份，`actor` / `author` 参数被忽略。

其余情况，写操作记在哪个 actor 名下，按优先级：

| # | MCP | REST |
|---|---|---|
| 1 | 工具参数 `actor` / `author`：只能是**同一用户**名下的 Agent，否则 `forbidden` | 请求头 `X-Helmsman-Actor`，同样只限本人名下 |
| 2 | 会话身份：`identify` 设置的 Agent | — |
| 3 | Token 的 `default_agent_id` | Token 的 `default_agent_id` |
| 4 | 自动名 `<人名>/session-<6位>`，首次写入时才创建 | 用户本人的 human actor（脚本代表本人操作） |

第 1 条的限制就是「防冒名」：bosun 里谁都能自称任何名字，这里只能以自己的身份或自己的 Agent 写入。

### `identify(name, project?, worktree?)`

- 名字不存在 → 创建 agent actor，`owner_id` = Token 的用户；
- 名字存在、是 **agent** 且属于本用户 → 复用，更新 `project_key` / `worktree` / `last_seen_at`；
- 名字是 human（包括用户自己的）或属于别人 → `{:error, :name_taken}`；属于停用的 Agent → `{:error, :agent_disabled}`。
- 上表第 1、3 条同理：参数覆盖和 Token 默认 Agent 也必须是**未停用、属于 Token 用户的 agent**。
- `identify` 是 Agent 唯一能做的「管理类」动作，只限于给自己的用户创建 Agent。
- `whoami()` 返回当前身份及来源（`identify` / `default` / `auto`）。

### 能防什么，不能防什么

身份解析保证：**写入记录的 actor 一定属于发起请求的那个用户**，用户之间不能冒名。
但同一用户名下的多个 Agent 之间不做隔离——用户本来就能随意创建 Agent。所以 05 §5 的自验收规则是**流程约束**而非安全边界：
同一用户换一个 Agent 去验收是允许的（「开发 Agent + 评审 Agent」本来就是合理的用法），历史里记着是谁验收的，人可以审计。

这一点会影响自动合并（15 §4）：缺省策略 `on_verified` 下，alice 的评审 Agent 验收了 alice 的开发 Agent 做的任务，PR 就会在 CI 通过后合并。
需要「必须有人看过才能进主分支」的项目，把合并策略设为 `on_verified_human`。

## 5. MCP 会话与 Presence

- `HelmsmanMCP.Sessions`：ETS 表，`MCP 会话 id → {token_id, actor_id}`。
- **会话绑定 Token**：anubis 按请求头 `Mcp-Session-Id` 找会话，且在调用我们的代码之前就处理了 GET（SSE 流）/ DELETE。所以：
  - `initialize` 时在 server 的 `init/2` 回调里登记 `session_id → token_id`；
  - 路由里在 anubis 之前加 `HelmsmanWeb.Plugs.MCPSessionGuard`：带会话 id 的**每个请求**（POST / GET / DELETE）都要求会话已登记且 `token_id` 与本次 Token 一致，否则返回 404（MCP 规范里「会话不存在」的响应，客户端会重新 initialize）。
    换句话说，会话 id 泄露了，没有同一个 Token 也用不了。
- **每个请求重新校验**：Token 未吊销 / 未过期、用户仍是成员、会话 actor 未停用——任一失败按 401 / 403 处理，不依赖会话里缓存的状态。
- 空闲超时：anubis 的会话超时与 ETS 过期统一配置为 24 小时；会话结束时删除登记。
- 会话建立 / 结束时在 `Phoenix.Presence` 主题 `workspace:<id>:agents` 上 track / untrack，界面据此显示在线的外接 Agent（托管 Agent 的状态来自运行时与运行，12 §3.4）。
- 服务重启后 MCP 会话全部失效，客户端会重新 initialize（MCP 规范要求）。新会话需要再 `identify`；
  `initialize` 返回的 `instructions` 会提醒这一点，Token 上设置 `default_agent_id` 可以免掉这一步。
- 单节点用 ETS 足够；多节点时挪到 Postgres 表 `mcp_sessions`。

# 08 · MCP 服务端

> 对应 bosun 的 05。把领域操作以 MCP 工具暴露给 Claude Code、Codex、Copilot CLI 等 Agent。工具名与参数尽量和 bosun 保持一致，已经写好的 Agent 提示词可以直接复用。

## 1. 端点与认证

- 只开 Streamable HTTP：`/mcp`。
- 每个请求必须带 `Authorization: Bearer hm_…`，Token 要有 `mcp` scope；无效 / 吊销 / 过期 → 401。
- **Token 决定工作区**，所以 URL 里不带 slug；一个 Agent 要访问两个工作区就配两个 Token。
- 托管 Agent 运行中用的是 `hmr_` 运行令牌（12 §4）：同一个端点、同一套工具，区别是身份固定为这个 Agent、运行结束令牌即失效、`identify` 只返回当前身份，并且只能做这次运行 `capabilities` 允许的事（缺省只能写本次运行的任务，13 §2.3）。

```elixir
# router.ex
pipeline :mcp do
  plug HelmsmanWeb.Plugs.BearerAuth, scope: "mcp"   # assigns.scope = %Scope{via: :mcp, ...}
  plug HelmsmanWeb.Plugs.MCPSessionGuard            # 会话必须属于同一个 Token（03 §5）
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: HelmsmanMCP.Server
end
```

anubis 把 `conn.assigns` 传进工具的 `frame.assigns`，工具从 `frame.assigns.scope` 拿到用户、工作区、角色，再按 03 §4 补上 actor。

客户端配置（设置页生成，可直接复制）：

```bash
claude mcp add --transport http helmsman https://helmsman.example.com/mcp \
  --header "Authorization: Bearer hm_xxxxxxxx"
```

## 2. 不绑定 MCP 库

工具写成普通模块，只依赖领域层：

```elixir
defmodule HelmsmanMCP.Tools.TransitionTask do
  use HelmsmanMCP.Tool,
    name: "transition_task",
    description: "Move a task to another status. ...",
    schema: %{task_id: {:string, required: true}, to: {:string, required: true}, ...}

  @impl true
  def call(%{"task_id" => id, "to" => to} = args, scope),
    do: Helmsman.Tasks.transition(scope, id, to, Map.take(args, ~w(comment commits tests)))
end
```

`HelmsmanMCP.Server`（`use Anubis.Server`）启动时把所有 `HelmsmanMCP.Tool` 模块注册上去，负责：取 scope → 解析 actor → 调 `call/2` → 把 `{:ok, map}` 转成 JSON 文本、`{:error, reason}` 转成 `isError: true` 加英文提示。要换 MCP 库（或自己实现协议）只改这一个模块。

## 3. 工具目录

与 bosun 的 22 个工具一致，按领域分组；描述用英文。工具随各自的领域分批交付（00 §9.4），M4 只交付领域已经存在的那部分。

| 组 | 工具 | 说明 |
|---|---|---|
| 身份 | `identify(name, project?, worktree?)` `whoami()` `list_actors()` | 见 03 §4；为兼容 bosun 也接受 `kind` 参数，但只能是 `agent` |
| 项目 | `list_projects(include_archived?)` `get_project(key)` `create_project(key, name, description?)` `update_project(key, …)` | 后两个需要 admin |
| 任务 | `list_tasks(project_key, status?, label?, kind?, epic?, assignee?, query?, limit?, offset?)` `search_tasks(query, project_key?, limit?)` `get_task(task_id)` `create_task(project_key, title, description?, priority?, labels?, kind?, epic?, assignee?)` `update_task(task_id, …)` | |
| 状态 | `transition_task(task_id, to, comment?, commits?, tests?)` | |
| 关联 | `link_tasks(from, to, type)` `unlink_tasks(from, to, type)` | |
| 反馈 | `add_feedback(task_id, content, kind?)` `update_feedback(feedback_id, content, kind?)` `list_feedback(task_id)` | |
| 查询 | `query_tasks(bql, filter_id?, limit?, offset?)` `list_filters()` `save_filter(name, bql, filter_id?, shared?)` `delete_filter(filter_id)` | `save_filter` 带 `filter_id` 是更新，不带是新建（与 bosun 一致） |

新增：

| 工具 | 说明 |
|---|---|
| `list_my_tasks(status?)` | 当前 actor 作为执行方的任务，外接 Agent 开工时最常用 |
| `list_agents()` | 本工作区的 Agent 与小队：名字、托管 / 外接、CLI、描述、当前是否忙 |
| `run_agent(agent, task_id?, instructions?)` | 手动触发一个托管 Agent（13 §2.1「手动」）；受 12 §2.1 约束 |
| `list_runs(task_id)` `cancel_run(run_id)` | 查看 / 停止运行 |
| `delegate(task_id, to, instructions)` | 只在小队 leader 的运行里可用：把同一任务委派给小队成员（16 §1.2） |

所有写工具都接受可选的 `actor` / `author` 参数（03 §4 第 1 条），正常不需要；运行令牌下被忽略。

## 4. 资源与提示

| 类型 | 名称 | 内容 |
|---|---|---|
| 资源 | `helmsman://workflow` | `docs/AGENT-WORKFLOW.en.md`：状态机、每一步该做什么、反馈约定（从 bosun 的同名文档改写，补上 Token、identify，以及托管运行里「提交但不要推送、不要开 PR」的约定） |
| 资源 | `helmsman://bql` | BQL 速查 |
| 资源 | `helmsman://projects` | 本工作区项目列表（JSON） |
| 资源模板 | `helmsman://tasks/{id}` | 任务详情（Markdown 渲染版，便于直接塞进上下文） |
| 提示 | `work_on_task(task_id)` | 任务全文 + 工作流规则 + 「先领取再动手」的指令 |

`initialize` 返回的 `instructions` 简要说明：先 `identify`，规则见 `helmsman://workflow`。运行令牌下改为说明「身份已固定，本次任务见提示词」。

## 5. 错误约定

成功返回 JSON 文本。失败时 `isError: true`，文本面向 Agent，写清**下一步该做什么**，集中在 `HelmsmanMCP.ErrorText`：

| reason | 文本示例 |
|---|---|
| `{:invalid_transition, from, to, allowed}` | `Cannot move BOS-3 from DONE to CANCELLED. Allowed: VERIFIED, IN_PROGRESS.` |
| `{:blocked, ids}` | `BOS-3 is blocked by BOS-1, BOS-2 (not DONE yet). Finish them first, or unlink_tasks if the dependency is wrong.` |
| `{:replaced, ids}` | `BOS-3 was replaced by BOS-7. unlink_tasks(BOS-7, BOS-3, replaces) first if it really needs to come back.` |
| `{:self_verify_requires_tests, name}` | `You (keel/search) are the assignee. Pass tests={passed:true,...} or let the requester verify.` |
| `:forbidden` | `Your role (viewer) cannot do this.` |
| `{:cannot_invoke, agent}` | `You may not trigger keel/dev (its owner limits who can run it). Ask its owner, or pick another agent from list_agents.` |
| `:run_ended` | `This run has ended; its token is no longer valid.` |
| `{:missing_capability, cap, task}` | `This run may only modify BOS-12. Creating tasks / touching BOS-15 needs the create_tasks capability; ask a human or write a question on BOS-12.` |
| `{:run_active, run}` | `BOS-12 cannot be verified while keel/dev is still running on it (run 881). Wait until the run ends and its changes are pushed.` |
| `:not_found` | `Task BOS-99 not found in workspace acme.` |
| `%Ecto.Changeset{}` | 字段名 + 错误信息逐条列出 |

## 6. 测试

- 单元：直接调每个工具的 `call/2`，覆盖成功与每种错误文本。
- 端到端：测试里起 endpoint，用 Req 走 initialize → tools/list → `identify` → `create_task` → `transition_task` → resources/read → prompts/get；另测无 Token / 吊销的 Token 得到 401。
- 手工验收（M4 完成标准）：用 `claude -p` 加 `--mcp-config`，以 Agent 身份跑通「建单 → 领取 → 提问 → 人在浏览器里回答 → 完成 → 人验收」，浏览器全程实时刷新。

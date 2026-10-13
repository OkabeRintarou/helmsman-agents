# Helmsman Agent 协作规则

Agent 与人如何通过 MCP 在 Helmsman 的任务上协作。每个会话读一次即可；MCP 资源
`helmsman://workflow` 返回的是英文版 `AGENT-WORKFLOW.en.md`，两版内容一致。

## 1. 角色

每个任务有三个角色。它们是任务上的位置，不是用户的种类：人和 Agent 都可以担任
任何一个。

- **提出方**：创建任务的身份（`created_by`），写清需求、回答关于需求的提问。
- **执行方**：做事的身份（`assignee`）。领取任务就成为它的执行方。
- **验收方**：把做完的任务置为 `VERIFIED` 的身份。通常是提出方；谁都可以，但要遵守
  第 5 节的自验收规则。

## 2. 接入与身份

需要一个带 `mcp` scope 的 API Token，由人在 Helmsman 的设置页创建。Token 决定工作区：
一个 Token 对应一个工作区。

```bash
claude mcp add --transport http helmsman https://helmsman.example.com/mcp \
  --header "Authorization: Bearer <token>"
```

你写入的一切（任务、状态迁移、Feedback）都记在某个身份名下。每个会话开始、写入之前，
先调用 `identify(name, project, worktree)`：

- `name` 用小写的「团队/角色」形式：`keel/dev`、`keel/review`、`coxswain/docs`。
  第一次调用会创建这个 Agent，归 Token 的主人所有；之后再调用就复用它。
- `project`、`worktree` 可选，只用来说明你在哪里工作。
- `whoami()` 显示当前身份及其来源。

一次写入记在哪个身份名下，按下面的顺序取第一个：

1. 写工具的 `actor` 参数（反馈工具叫 `author`）：同一个人名下的另一个 Agent，只对这一次
   调用生效；
2. `identify` 设置的会话身份；
3. Token 的缺省 Agent（如果有人配置了）；
4. 都没有时，首次写入自动创建 `<人名>/session-<编号>`，本会话内沿用。

你永远不能以人的身份、或别人的 Agent 的身份写入。服务重启后会话失效：重新连接后要再调用
一次 `identify`。

## 3. 状态与迁移

| 状态 | 含义 |
|---|---|
| `NEW` | 已创建，还没人开始做 |
| `IN_PROGRESS` | 正在做 |
| `DONE` | 做完，等待验收 |
| `VERIFIED` | 验收通过，正常流程的终点 |
| `REJECTED` | 执行方认为需求本身不对，拒绝执行 |
| `CANCELLED` | 不再需要 |

状态名不区分大小写，也可以用空格或连字符：`IN_PROGRESS`、`in progress`、`in-progress`
是同一个状态。工具输出的状态名一律大写。

允许的迁移；其他迁移会被拒绝，错误文本列出当前可以去的状态：

| 从 | 可以去往 | 场景 |
|---|---|---|
| `NEW` | `IN_PROGRESS`, `REJECTED`, `CANCELLED` | 领取；拒绝；撤销 |
| `IN_PROGRESS` | `DONE`, `REJECTED`, `CANCELLED` | 完成；拒绝；撤销 |
| `DONE` | `VERIFIED`, `IN_PROGRESS` | 验收通过；打回 |
| `VERIFIED` | `IN_PROGRESS` | 重开 |
| `REJECTED` | `NEW` | 改完需求后重新提交 |
| `CANCELLED` | `NEW` | 恢复 |

`VERIFIED`、`REJECTED`、`CANCELLED` 是关闭状态：任务会一直停在那里，直到有人重开、
重新提交或恢复它。

## 4. 每一步做什么

**找活。** `list_my_tasks()` 列出指派给你的任务（缺省为 NEW 与 IN_PROGRESS）。
`list_projects()`、`list_tasks(project_key)` 可以看其他任务。

**先读再动。** `get_task(task_id)` 返回描述、完整历史和全部 Feedback。`open_question`
为真表示有提问在等回答：不要开工。

**领取。** 改任何文件之前，先 `transition_task(task_id, "IN_PROGRESS")`。任务没有执行方时
这一步会把你设为执行方，别人就知道它已经有人在做。

**拿不准就问。** 需求有歧义、或者某个决定不该由你来做时，
`add_feedback(task_id, content, kind: "question")`，然后停止这个任务、结束本轮。人会写一条
`answer`；继续之前先用 `get_task` 读到它。不要猜。

**完成。** 做完并提交之后：

1. `add_feedback(task_id, content, kind: "comment")`，写清改了什么、验收方需要知道什么；
2. `transition_task(task_id, "DONE", commits: [...], tests: {command, passed,
   summary})`。`commits` 是完整或缩写的提交哈希（7–64 位十六进制）；`tests` 是你运行的
   命令及结果。

这样证据都在历史里，验收方不用到处翻。

**验收。** 作为验收方，读历史和 Feedback，然后二选一：

- 通过：`transition_task(task_id, "VERIFIED")`；
- 打回：`transition_task(task_id, "IN_PROGRESS", feedback: {kind:
  "review", content: "缺了什么"})`。原因作为 Feedback 在同一步里保存，历史条目指向它。

**拒绝。** 需求本身不对（不只是难做）时，执行方把任务迁移到 `REJECTED`，并附一条说明原因
的 `review` Feedback。提出方改好描述后再把它迁回 `NEW`。

**撤销。** 任务不再需要时，任何人都可以把它迁移到 `CANCELLED`，最好在 `feedback` 里写上
原因。

**改字段。** `update_task(task_id, ...)` 修改标题、描述、优先级、标签和执行方，不能改状态。
带上你读到的 `lock_version`，可以避免覆盖别人的修改。

## 5. 自验收

如果你是任务的执行方，只有带着通过的测试证据才能验收自己的工作：本次 `VERIFIED` 迁移的
`tests` 带 `passed: true`，或者最近一次迁移到 `DONE` 时带了。否则调用会被拒绝；请把验收
留给提出方。

同一个人名下的另一个身份（评审 Agent 验收开发 Agent 的任务，或者人验收自己 Agent 的工作）
不算「本人」。历史里记着是谁验收的，人可以审计。

执行方是小队时，整个执行方一侧都算执行方：小队本身、它的 leader 与全部成员（含人），
见第 9 节。

## 6. Feedback

Feedback 是任务下的 Markdown 记录，ID 形如 `BOS-12#3`。共四种：

| 种类 | 用途 |
|---|---|
| `comment` | 一般说明；完成时的改动说明 |
| `review` | 评审结论：打回、拒绝或通过的理由 |
| `question` | 需要对方决定的事；回答之前停下 |
| `answer` | 对提问的回答 |

只要任务最后一条有效的提问或回答是提问，任务就处于待回答状态；只有 `answer` 能关掉它。

记录不会被删除，也不会原地修改。要更正一条记录，用 `update_feedback(feedback_id, content)`：
一条新记录取代它，旧记录保留为 `superseded`。只能修订记录的当前版本，且只能由作者本人或
同一个人名下的其他身份修订。`list_feedback(task_id)` 显示全部记录，含已作废的。

## 7. 错误

工具失败时，错误文本会说明出了什么问题、下一步该做什么，并带上相关的 ID，例如：

- `Cannot move BOS-3 from DONE to CANCELLED. Allowed: VERIFIED, IN_PROGRESS.`
- `BOS-3 was changed by someone else since you read it. Call get_task ...`

读懂它并照做，不要原样重试。文本是 `Internal error (ref ...)` 时是服务端的问题：带着 ref
告诉人。

## 8. 托管运行

由 Helmsman 自己启动你时（托管运行），提示词会写明你的任务，并在以上规则之外再加几条：

- 本次运行的身份是固定的；`identify` 只报告当前身份，`actor` / `author` 参数被忽略；
- 只处理本次运行的任务，除非提示词另有说明；
- 提交你的改动，但不要推送、不要开 PR、不要切换分支：这些由 Helmsman 负责；
- 结束方式同第 4 节：一条 `comment`，再带 `commits` 和 `tests` 迁移到 `DONE`；或者提一个
  `question` 后停下。

## 9. 小队

小队是一个由 leader（托管 Agent）带领、有若干成员（托管 Agent 与人）的团队。把任务指派给
小队或 @小队，会启动它的 leader；`list_agents` 列出各小队及其成员。

本次运行你以小队 leader 身份运行（提示词里有小队一节）时：

- 本任务上的工作用 `delegate(task_id, to, instructions)` 交给成员 Agent。成员在同一任务、
  同一分支和 PR 上工作，但要等你的运行结束才开始：委派之后结束本次运行，不要等待；
- 可以独立交付的部分拆成子任务（`create_task`，执行方填成员）；改代码优先委派，改动都落在
  同一个 PR 里；
- 被委派的运行结束（带成员的最后输出）、你建的子任务完成或被拒绝、子任务执行方提问时，你会
  被唤醒；
- 你不能创建 Agent，也不能修改小队：缺少角色时在任务上写一条 `question`，由人补充；
- 目标全部达成后，带提交与测试把任务迁移到 `DONE`；由提出方验收，不要自己或让成员验收。

你作为成员被委派时：按 leader 的指示做，结束时写一段简短的总结（leader 会看到）。除非
leader 要求，不要把任务迁移到 `DONE`，也不要验收它。

## 10. 在其他仓库里引用

在仓库的 `CLAUDE.md`（或你所用 Agent 的同类文件）里加一行：

```markdown
Tasks live in Helmsman (MCP server "helmsman"). Read the resource helmsman://workflow and follow it.
```

另有两个 MCP 捷径：

- 资源 `helmsman://tasks/{id}` 以 Markdown 返回一个任务；
- 提示 `work_on_task`（参数 `task_id`）返回任务、本规则全文，以及领取、动手、完成的指令。

---

章节结构参考 bosun 的 AGENT-WORKFLOW 文档（Apache-2.0）；文字按 Helmsman 自己的规则编写。

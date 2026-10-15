# 06 · Feedback

> 对应 bosun 的 04，语义不变；新增 @提及和与运行的联动（§3a、§3b）。

## 1. 定位

Feedback 是任务下**不可变、只追加**的 Markdown 记录，用于人与 Agent 之间的往返。可以回复某一条（§2a），但不是聊天：**没有删除**（Agent 可能已经读过并引用了它）。

| kind | 用途 |
|---|---|
| `comment` | 一般说明；完成时的改动记录 |
| `review` | 评审意见：打回、拒绝、通过时的备注 |
| `question` | 需要对方决定；提了就停下等 |
| `answer` | 回答 question |

ID 形如 `BOS-12#3`（任务 ident + `#` + 任务内序号）。

## 2. 修订

- 修订 = 追加一条新记录，`supersedes_id` 指向旧的；旧记录 `status = superseded`、`superseded_by_id` 指向新的。一串修订就是一条线索。
- 新记录的 `seq` 照常递增（ID 是新的 `#N`），但 `thread_seq` 沿用线索第一条的 `seq`——它决定这条线索在时间线上的**位置**，修订不会把旧内容挪到最后。
- 只有原作者 actor 能修订，否则 `:forbidden`。例外：同一用户名下的 actor 之间可以互相修订（人修正自己 Agent 写错的内容），记录里作者仍是实际操作的 actor。
- 已作废的不能再修订：`{:superseded, latest_id}`，提示去改最新那条。
- `feedback_count` 只算有效（active）记录，列表、详情、BQL 口径一致。（bosun 的 JSON 只算有效记录，BQL 却连作废的一起算，这里统一了。）
- 作废记录的 `search` 列置空，不会被搜到。

## 2a. 回复

- 写入时可以带 `reply_to`（同任务里任意一条记录的 ID，含早期版本）：记下 `reply_to_seq`（实际被回复的那条记录）与 `reply_root_seq`（顶层根线索的 `thread_seq`：目标已有根就继承，否则取目标的 `thread_seq`）。修订继承这两个字段，不能改回复目标；不存在、跨任务的目标是字段错误（`add-feedback-replies` 决策 1–2）。读取时每条带 `reply_to`、`reply_root` 与 `target`（目标线索当前版本的 ID、序号、作者、首行摘要，以及原目标记录的状态，已修订时界面标「已修订」）。
- **回复树**（`add-nested-feedback-replies`）：父线索 = `reply_to_seq` 那条记录所在的线索，所以回复早期版本也挂在该线索下。回复目标在线索内恒定、目标序号小于回复的序号，沿父链 `thread_seq` 严格递减——无环，多层嵌套不需要新数据。根与兄弟按 `thread_seq` 排（修订不改变位置）。界面缩进最多 3 层，更深的压平在第 3 层；只有显示位置不是实际目标时才标「回复 @作者 #n」与目标摘要；回复可收起 / 展开（09 §3）。
- **回复时预填 @**：人在网页上点「回复」时，内容预填 `@<被回复记录的作者> `（作者是自己或系统身份时不填），可改可删，提交后按 §3a 照常解析与派发。服务端**不**为回复自动加不在内容里的提及：提及以内容为唯一来源，修订「只算新增」才成立；人也能选择只记一笔、不叫醒 Agent；Agent 之间的回复也不会因此互相唤醒。
- 不改 MCP / REST / 提示词：Agent 按 ID 读写，`TaskMarkdown` 与触发引用显示「回复 #n @作者」。

## 3. 待回答

`open_question = true` 当且仅当：在有效的 `question` / `answer` 记录中，按 `thread_seq` 排最后的是 `question`。

与 bosun 的差别（有意为之）：

| 情况 | bosun | Helmsman |
|---|---|---|
| 提问后有人只写了 `comment` / `review` | 不再算待回答 | 仍是待回答——只有 `answer` 能关掉 |
| 修订一个已经被回答过的提问 | 修订版是最新一条 → 重新变成待回答 | 修订版继承原位置，仍排在回答之前 → 不变 |

在写 / 修订 Feedback 的同一事务里重算（01 §4）。列表、详情页头、BQL（`question = true`）都用这个字段，后续的收件箱（00 §10）也从它出发。

## 3a. @提及

- 内容里的 `@名字`（不在代码块、行内代码、链接文本里）解析为本工作区的 actor；解析在写入时做一次，结果存进 `feedback.mentions bigint[]`，界面渲染成 `ActorChip`。
- @托管 Agent 或 @小队 → 触发运行（13 §2.1「提及」）；@人 只是标注（以后接收件箱）。外接 Agent 被 @ 不会被唤醒——它不在 Helmsman 的控制之下。
- 修订时只对**新增**的提及触发，原来就有的不重复触发。
- 一条记录对同一个目标只触发一次：同时是对它的「回答」或「回调提出方」又 @了它时，按 回答 > 回调提出方 > 提及 的顺序在同一事务里逐个尝试，各用自己的授权来源与检查；某个排上队（`queued` / `merged`）后，余下的提及记为 `skipped / covered`、卡片上说明「已由这条记录的回答唤醒」——避免同一个 Agent 被 `work` 与 `reply` 两条运行各叫醒一次。前者被跳过（如 `no_grant`、继承的发起人已无权）或被依赖延后（`deferred`）时，提及照常按写的人的授权派发，不算覆盖。只有这次写入实际产生的触发参与：修订已回答的回答时新增的 @ 照常触发（`add-nested-feedback-replies` 决策 12）。
- 系统身份 `helmsman` 写的 Feedback 与兜底回帖不触发。每条记录引起的触发结果（Agent、种类、结果、原因、运行）保存在 `feedback.dispatch` 上，读取时随记录返回（`add-continuation-triggers` 决策 10）。
- 触发者无权触发被 @ 的 Agent 或小队时（12 §2.1、16 §1.1；触发者是作者本人，托管 Agent 在运行中写的则是那次运行的授权来源，13 §2.2），Feedback 照常保存，提及显示为灰色并说明原因。

## 3b. 与运行的联动

- **回答触发**：`answer` 让 `open_question` 变为 false，且那条 `question` 是托管 Agent 写的 → 为它建运行（13 §2.1「回答」），lane 与授权都接续提问所在的那次运行。
- **回调提出方**：执行方写了 `question`，而任务的提出方是开启了 `wake_on_requested` 的托管 Agent → 唤醒提出方（13 §2.1「回调提出方」）。
- **插话**：有 Agent 正在这个任务上运行时，人写的 Feedback 可以同时送进那次运行；作者须是人且有权触发该 Agent，只在追加时可用（13 §8）。
- **兜底回帖**：托管 Agent 一次运行里一条 Feedback 都没写时，服务端以它的名义把最后输出写成 `comment`（13 §7）。
- **系统身份**：`helmsman` 写的 Feedback（CI 失败、防循环备注等）在界面上用系统样式显示，不能被修订。

## 4. 领域 API（`Helmsman.Feedback`）

| 函数 | 说明 |
|---|---|
| `add(scope, ident, %{kind, content})` | 锁任务，分配 `seq`，插记录（含解析出的 `mentions`），更新任务的计数 / 待回答 / `updated_at` / 检索列，按 §3a / §3b 触发运行 |
| `revise(scope, feedback_id, %{content, kind?})` | 同一事务：插新记录 + 作废旧记录 |
| `list(scope, ident)` | 含作废记录，按 seq 升序 |
| `get(scope, feedback_id)` | |

成功后在 `task:<id>` 广播 `{:feedback_added, feedback}`，在 `project:<id>` 广播 `{:task_updated, summary}`（计数变了）。

## 5. 接口

- MCP：`add_feedback(task_id, content, kind?, author?, reply_to?)` · `update_feedback(feedback_id, content, kind?, author?)`（返回新记录）· `list_feedback(task_id)`；`get_task` 内嵌全部 Feedback。
- REST：`GET/POST /api/v1/w/:slug/tasks/:id/feedback`；`PATCH /api/v1/w/:slug/feedback/:feedback_id` → 201 新记录；403 非作者；409 已作废。
- 界面：见 09 §3。

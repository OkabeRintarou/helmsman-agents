# 06 · Feedback

> 对应 bosun 的 04，语义不变；新增 @提及和与运行的联动（§3a、§3b）。

## 1. 定位

Feedback 是任务下**不可变、只追加**的 Markdown 记录，用于人与 Agent 之间的往返。不是聊天：没有线程回复，**没有删除**（Agent 可能已经读过并引用了它）。

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
- 触发者无权触发被 @ 的 Agent 或小队时（12 §2.1、16 §1.1；触发者是作者本人，托管 Agent 在运行中写的则是那次运行的授权来源，13 §2.2），Feedback 照常保存，提及显示为灰色并说明原因。

## 3b. 与运行的联动

- **回答触发**：`answer` 让 `open_question` 变为 false，且那条 `question` 是托管 Agent 写的 → 为它建运行（13 §2.1「回答」）。
- **插话**：有 Agent 正在这个任务上运行时，人写的 Feedback 可以同时送进那次运行（13 §8）。
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

- MCP：`add_feedback(task_id, content, kind?, author?)` · `update_feedback(feedback_id, content, kind?, author?)`（返回新记录）· `list_feedback(task_id)`；`get_task` 内嵌全部 Feedback。
- REST：`GET/POST /api/v1/w/:slug/tasks/:id/feedback`；`PATCH /api/v1/w/:slug/feedback/:feedback_id` → 201 新记录；403 非作者；409 已作废。
- 界面：见 09 §3。

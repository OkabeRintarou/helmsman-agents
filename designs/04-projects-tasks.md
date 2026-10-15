# 04 · 项目与任务

> 对应 bosun 的 01、02。语义基本照搬，差异：项目 Key 在**工作区内**唯一；actor 是有类型、有归属的身份；字段编辑加了乐观锁。

## 1. 项目

| 字段 | 规则 |
|---|---|
| `key` | `^[A-Z][A-Z0-9]{1,9}$`，输入转大写后校验；工作区内唯一；**创建后不能改**（它是所有任务 ID 的一部分） |
| `name` / `description` | 可改；描述是 Markdown |
| `task_seq` | 已分配的最大序号；对外 `task_count` 就是它（任务不能删，两者相等） |
| `archived_at` | 归档后默认不在列表里显示、不能新建任务；已有任务照常可读、可迁移 |
| 代码与合并 | `repository_id`、`base_branch`、`merge_policy` 等，见 15 §2、§4 |

不做删除：项目 Key 永不复用，任务 ID 才能永远唯一。

领域 API（`Helmsman.Projects`）：`create/2`、`get!/2`（按 key）、`list/2`（`include_archived`）、`update/3`、`archive/2`、`unarchive/2`。

## 2. 任务

### 2.1 字段

| 字段 | 说明 |
|---|---|
| `ident` | `KEY-N`，N 从 1 开始、项目内递增、永不复用；解析不区分大小写（`bos-12` = `BOS-12`），不允许前导零 |
| `title` | 必填，≤ 200 字 |
| `description` | Markdown，≤ 64 KB |
| `status` | `new` `in_progress` `done` `verified` `rejected` `cancelled`，只能经状态迁移修改（05） |
| `priority` | `low` < `medium` < `high`，缺省 `medium` |
| `labels` | 去空白、转小写、去重；每个 ≤ 32 字，最多 20 个 |
| `kind` | `task` \| `epic`，建单后不能改 |
| `epic_id` | 所属 Epic，可以跨项目（同一工作区内） |
| `created_by_id` | 提出方，创建时的 actor |
| `assignee_id` | 执行方：人、Agent 或小队（不能是 `system`）。建单 / 编辑时可以预派；领取（NEW → IN_PROGRESS）时若为空，自动写成当前 actor。指派给**托管 Agent 或小队**会触发运行（13 §2），除非请求带 `start: false`（界面上的「暂不开始」） |

### 2.2 对外形态（MCP / REST 用的 map）

- **摘要**：`id`（即 ident）`project_key title status priority labels kind epic created_by assignee commits blocked progress feedback_count open_question run pr created_at updated_at`
  - `created_by` / `assignee` 是 `{name, kind}`；
  - `commits` = 所有历史条目里的提交 hash，去重后按时间排；
  - `progress` 只有 Epic 有；
  - `run` = 最近一次运行的 `{agent, status}`（13），`pr` = `{number, url, state, checks_state, merge_status}`（15 §3），没有则为 null。
- **详情**：摘要 + `description history feedback links runs`；Epic 再加 `children`（步骤摘要，每项另带 `waiting_for`——这个步骤在等谁：`merge` / `verification` / `requester` / `answer` / `run` / `prerequisites` / `assignment` / `assignee` / `start`，`start` = 托管执行方但没有任何运行、不会有人自动启动它；`blocked_by` 未满足的前置；运行令牌读取时 `orchestrable`，16 §1.2，`improve-squad-leader-orchestration` 决策 13），普通任务加 `epic_title`。与链项上的 `waiting_for`（07 §3，前置为什么还不满足）是两回事。

### 2.3 领域 API（`Helmsman.Tasks`）

| 函数 | 说明 |
|---|---|
| `create(scope, project_key, attrs)` | 同一事务：分配序号（01 §4）、插任务、插创建事件（`from = nil, to = new`）、写检索列、按指派触发运行（13 §2） |
| `get(scope, ident)` | 详情，预加载历史、Feedback、关联、运行、PR |
| `list(scope, project_key, opts)` | `status` / `label` / `kind` / `epic` / `assignee` / `q` / `limit` / `offset` |
| `update(scope, ident, attrs, lock_version \\ nil)` | 改标题 / 正文 / 优先级 / 标签 / 指派 / Epic；**忽略** `status`；给了版本且不对返回 `{:error, :stale}`；指派变化时同一事务里触发运行 |

MCP / REST 调 `update` 时可以不传 `lock_version`，此时在行锁内按最新值修改，即后写覆盖（01 §4）：Agent 很少和人同时改同一张单的正文，强制它带版本号只会多出一类错误。界面始终带版本号。

## 3. Epic

Epic 就是 `kind = epic` 的任务：一个整体目标，普通任务通过 `epic_id` 挂上去作为步骤。

- 校验：`epic_id` 必须指向同一工作区内 `kind = epic` 的任务；Epic 不能再挂到别的 Epic 下；`epic = ""` 表示摘掉。目标的状态不限：挂到已 DONE / VERIFIED 的 Epic 会使它自动回到 IN_PROGRESS（05 §6）。`kind` 建单后不能改，编辑请求带不同的 `kind` 返回字段错误（`add-epics` 决策 3）。
- 步骤按创建顺序（任务 ID 的内部主键）列出，没有显式顺序；需要先后时用依赖表达（07）。
- `progress = %{total, done, by_status}`：一次聚合查询 `GROUP BY status` 得到；DONE 与 VERIFIED 算完成，CANCELLED / REJECTED 计入 total 但不算完成。不落库。
- 有自己的状态、历史和 Feedback，走同一个状态机；另外随步骤自动流转（05 §6）。

## 4. 广播

`create` / `update` 成功后：

| 主题 | 消息 |
|---|---|
| `project:<id>` | `{:task_created, summary}` / `{:task_updated, summary}` |
| `task:<id>` | `{:task_updated, ident}`（详情页收到后重新加载） |
| `task:<epic_id>` | 步骤挂上 / 摘下 / 状态变化时通知 Epic 页面刷新进度：沿用 `{:task_updated, ident}`，Epic 所在项目主题同时收到 `{:task_updated, summary}`（`add-epics` 决策 9） |

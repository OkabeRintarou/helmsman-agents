# 16 · 小队与自动化

## 1. 小队

> 一组 Agent（和人）组成的团队，由一个 **leader Agent** 带领。把任务交给小队，由 leader 决定谁来做、怎么拆。

### 1.1 模型

- 小队本身是一个 actor（`kind = squad`，03 §1），所以能像人和 Agent 一样被指派、被 @提及、出现在 BQL 里（`assignee = backend-team`）。小队**不会**成为任何记录的作者。
- `squads`：`actor_id`、`leader_agent_id`、`instructions`（团队的分工与工作方式，Markdown）。
- `squad_members`：`squad_id`、`actor_id`（托管 Agent 或人）、`role_note`（这个成员擅长什么，给 leader 看）。
- 一个 Agent 可以是多个小队的 leader。以 leader 身份的运行都带 `squad_id`（13 §1），提示词用哪份小队说明、`delegate` 能派给谁、排队合并都按它区分。
- 创建 / 修改小队：admin 以上，或 leader Agent 的所属用户。保存时检查：leader 的所属用户有权触发每一个 Agent 成员（12 §2.1），否则拒绝并列出无权的成员。

### 1.2 怎么运转

1. 任务指派给小队，或在 Feedback 里 @小队 → 为 **leader** 建运行（13 §2）。提示词额外包含小队的 `instructions` 和成员名单（名字、类型、擅长什么、用哪个 CLI）。
2. leader 有两种派活方式：

| 方式 | 怎么做 | 适合 |
|---|---|---|
| **委派** | MCP 工具 `delegate(task_id, to, instructions)`：在**同一个任务**上为成员建一次运行（触发类型 `delegated`，带上 leader 的指示）。同一任务一次只跑一个运行（13 §3），所以成员要等 leader 这次运行**结束**才开始——提示词明确告诉 leader：委派之后就结束本次运行，不要等结果，成员做完你会被唤醒。共用同一个分支、同一个 PR | 顺序协作：实现 → 评审 → 修改；**改代码优先用这种** |
| **拆分** | 用 `create_task` 建子任务，`assignee` 设为成员，`epic` / `depends_on` 组织顺序 | 可以并行、可以独立交付的部分 |

3. leader 何时被再次唤醒：
   - 委派出去的运行结束 → 触发 `delegate_done`，提示词带上成员的最后输出；
   - 它建的子任务进入 DONE / REJECTED 或有人提问 → 13 §2.1 的「回调提出方」，leader 去验收或回答。
4. 整体目标达成后，leader 把父任务置为 DONE；之后由**父任务的提出方**验收。

- `delegate` 只允许 leader 在自己小队负责的任务上调用（运行需要 `delegate` 能力，13 §2.3），`to` 必须是小队里的托管 Agent。人类成员不能被委派运行；leader 需要人拍板时，照常写 `question`。
- 防循环规则（13 §7）同样适用：委派是 Agent 引起的新发起，成员运行的触发链包含 leader。

### 1.3 和验收、合并的关系

自动合并要求验收独立于代码的出处（15 §4.1）。放到小队里：

- **父任务**：小队本身、leader 和所有成员都不独立。小队内部的人或 Agent 验收父任务算自验收（05 §5）：要带通过的测试，且不触发自动合并。否则 leader 让自己的评审成员点 VERIFIED，代码就能不经外部验收进入主分支。父任务应由小队外的提出方验收。
- **拆分出的子任务**：成员的运行是 leader 引起的，leader 在出处里，所以 leader 验收子任务同样不触发自动合并，子任务的 PR 需要外部验收或手动合并。这就是上面推荐「改代码优先用委派」的原因：委派让全部改动落在父任务的一个 PR 里，只需要外部验收一次。

## 2. 自动化

> 按计划、手动或 webhook 触发一个 Agent 去做预设的工作，例如每天整理新任务、每周升级依赖、CI 夜间失败时排查。

### 2.1 模型

| 表 | 列 |
|---|---|
| `autopilots` | `workspace_id`、`name`、`agent_id`、`project_id`（可空）、`mode`、`title_template`、`instructions`、`cron`、`timezone`、`overlap`（`skip` 缺省 \| `queue`）、`enabled`、`next_run_at`、`webhook_token_hash`（可空）、`created_by_user_id`、时间戳 |
| `autopilot_runs` | `autopilot_id`、`source`（`schedule` \| `manual` \| `webhook`）、`delivery_id`、`initiator_user_id`、`payload jsonb`（webhook 请求体，截断到 64 KB）、`task_id`、`run_id`、`status`（`pending` \| `skipped` \| `started` \| `succeeded` \| `failed`）、`result`、`inserted_at` |

### 2.2 两种模式

| 模式 | 做什么 | 结果在哪 |
|---|---|---|
| `create_task` | 在 `project` 里建一张任务：标题来自模板（支持 `{{date}}` `{{source}}`），正文是 `instructions` + webhook 内容摘要，执行方是这个 Agent，标签 `autopilot`，提出方是自动化创建者本人的 human actor。之后完全按普通任务走：指派触发、分支、PR、验收、合并 | 那张任务 |
| `run_only` | 不建任务，直接为 Agent 建一次运行（`task_id` 为空），提示词是 `instructions` + 触发来源 + payload。有仓库时在基础分支的临时 worktree 里跑，**不推送**任何改动 | `autopilot_runs.result`（Agent 的最后输出）；Agent 也可以通过 MCP 建任务、写反馈 |

`run_only` 适合「看一看然后建工单 / 写评论」这类工作；要改代码就用 `create_task`，这样改动有任务、有 PR、有验收。

### 2.3 调度

- 保存时用 `crontab` 库按时区（`tz` 时区库）算出 `next_run_at`，并插入一个 Oban 任务 `AutopilotFire`，`scheduled_at = next_run_at`，唯一键 `(autopilot_id, next_run_at)` 防止重复。
- 触发时（定时、手动、webhook 都一样）先 `SELECT … FOR UPDATE` 锁住这条自动化，再检查上一次是否还在进行（它建的任务还没结束，或它的运行还没结束）。`autopilot_runs` 上有部分唯一索引 `(autopilot_id) WHERE status = 'started'` 兜底，同一时刻最多一次在进行：
  - `skip`：记一条 `skipped`；
  - `queue`：记一条 `pending`（最多保留 1 条，多的合并）；上一次结束时（任务进入终态或运行结束的处理里）把它变成 `started` 并执行；
  - 否则直接执行；然后算下一次时间，插入下一个 `AutopilotFire`。
- 服务停机错过的时间：只补触发一次（错过超过 1 小时则直接跳到下一个未来时间），不会在恢复时连续补跑。
- 启动时有一个对账任务，确保每个启用的自动化都有一个排好的 `AutopilotFire`。

### 2.4 触发方式

- **定时**：cron 表达式 + 时区，界面上用人话预览（「每个工作日 09:00（Asia/Shanghai）」）和接下来 5 次的时间。
- **手动**：自动化页面上的「立即运行」，可以临时附加一段说明。
- **Webhook**：`POST /hooks/autopilots/:id`，`Authorization: Bearer <令牌>`（创建时显示一次）；请求体作为 payload。按令牌限流，每分钟 10 次。

- Webhook 令牌是 32 字节随机数，只存哈希，可以随时轮换；请求带 `X-Delivery-Id` 时按它去重（24 小时内），重复投递不会重复触发。

### 2.5 权限与失败

- 创建 / 修改自动化：有权触发该 Agent 的成员（12 §2.1）。定时和 webhook 触发的授权来源是自动化的创建者；手动触发的是点按钮的人（他也必须有权触发这个 Agent）。授权来源离开工作区或失去触发权限时，自动化自动停用，并在页面上说明原因。
- 自动化建出的运行能力范围（13 §2.3）：`create_task` 模式同普通任务；`run_only` 模式没有任务可写，只有 `read`，外加在自动化配置里勾选的 `create_tasks`。
- `run_only` 的运行失败**不自动重试**，避免和下一次计划执行重叠；`create_task` 建出的任务按普通运行的规则重试（13 §5）。
- 连续失败 5 次自动停用，等人检查。

## 3. 界面

- `/w/:slug/squads`：小队列表与编辑（leader、成员、说明）。
- `/w/:slug/autopilots`：列表（下次时间、最近结果、启用开关）；详情页是配置和触发历史，每一条链到对应的任务或运行记录。
- 指派选择器里人、Agent、小队分组显示；无权触发的 Agent 置灰并说明原因。

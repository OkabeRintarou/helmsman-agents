# 16 · 小队与自动化

## 1. 小队

> 一组 Agent（和人）组成的团队，由一个 **leader Agent** 带领。把任务交给小队，由 leader 决定谁来做、怎么拆。

### 1.1 模型

- 小队本身是一个 actor（`kind = squad`，03 §1），所以能像人和 Agent 一样被指派、被 @提及、出现在 BQL 里（`assignee = backend-team`）。小队**不会**成为任何记录的作者。
- `squads`：`actor_id`、`leader_agent_id`、`description`（≤ 500 字符）、`instructions`（团队的分工与工作方式，Markdown，≤ 16 KB）。
- `squad_members`：`squad_id`、`actor_id`（托管 Agent 或人）、`role_note`（这个成员擅长什么，给 leader 看，≤ 500 字符）。最多 16 个成员；leader 必须是未归档的托管 Agent，不在成员名单里；成员不能是外接 Agent、系统、小队。
- 成员就是普通的托管 Agent：同一个 CLI、同一台机器可以有多个成员，各自配置模型、推理强度与指令（例如一个写前端、一个评审、一个测试，12 §2）。
- **Leader 不能创建 Agent**（用户要求）：运行里没有任何创建 Agent、创建或修改小队的能力，leader 只能把工作派给现有成员或建任务指派给他们；缺少角色时写 `question` 请人补充，人用对话创建（§1.4、12 §6）。
- **规格定稿方式** `spec_finalize`（17 §4）：空 = 继承项目（缺省），`approval` = leader 提出、人批准，`leader` = leader 自己定稿；设为 `leader` 只限 admin，能管理小队的人可以收紧。不随工作区导出（小队配置）。
- 一个 Agent 可以是多个小队的 leader。以 leader 身份的运行都带 `squad_id`（13 §1），提示词用哪份小队说明、`delegate` 能派给谁、排队合并都按它区分。
- **谁能触发小队**：能触发 leader，并且能触发小队里每一个托管 Agent 成员（12 §2.1；人类成员不影响）。指派给小队、@小队时按这条校验触发者（13 §2.2）；不满足时同 12 §2.1：指派照常保存、不产生运行，并列出是哪些成员挡住了。
- 创建 / 修改 / 停用小队：admin 以上，或 leader Agent 的所属用户（改 leader 时还要是新 leader 的所属用户）。停用 = 小队身份停用：取消排队的 leader 运行、停止进行中的；换 leader 取消旧 leader 的排队运行；归档的 Agent 自动退出所有小队（`add-squads` 决策 3）。保存时不做授权检查，而是提示：哪些成员（含 leader）的 `access` 不是 `workspace`、因此让工作区里多数成员无法触发这个小队，并显示「能触发这个小队的成员 N / M」。

### 1.2 怎么运转

1. 任务指派给小队，或在 Feedback 里 @小队，且触发者能触发这个小队（§1.1）→ 为 **leader** 建运行（13 §2）。提示词额外包含小队的 `instructions` 和成员名单（名字、类型、擅长什么、用哪个 CLI）。
2. leader 有两种派活方式：

| 方式 | 怎么做 | 适合 |
|---|---|---|
| **委派** | MCP 工具 `delegate(task_id, to, instructions)`：在**同一个任务**上为成员建一次运行（触发类型 `delegated`，带上 leader 的指示）。同一任务一次只跑一个运行（13 §3），所以成员要等 leader 这次运行**结束**才开始——提示词明确告诉 leader：委派之后就结束本次运行，不要等结果，成员做完你会被唤醒。共用同一个分支、同一个 PR | 顺序协作：实现 → 评审 → 修改；**改代码优先用这种** |
| **拆分** | 用 `create_task` 建子任务，`assignee` 设为成员，`epic` 归组、`depends_on`（建任务时直接给出前置任务的 ID）排顺序；尽量一次建齐，前置未完成的子任务按 13 §2.4 推迟、前置完成后自动开工；之后的调整（补启动、换人、补排顺序）用下面的编排 | 可以并行、可以独立交付的部分 |

3. leader 何时被再次唤醒：
   - 委派出去的运行结束 → 触发 `delegate_done`，提示词带上成员的最后输出；
   - 它建的子任务进入 DONE / REJECTED 或有人提问 → 13 §2.1 的「回调提出方」，leader 去验收或回答；
   - 它负责的 Epic 停住（有闲置步骤、什么都没在跑）→ `epic_stalled`（下文「停滞唤醒」）；
   - 人 @leader 或手动运行 leader，而任务（或其 Epic）归它的小队 → 以小队身份运行（下文）。
4. 整体目标达成后，leader 把父任务置为 DONE；之后由**父任务的提出方**验收。

- `delegate` 只允许 leader 在以小队身份的运行里、对本次运行的任务（执行方是这个小队、在 NEW / IN_PROGRESS）调用（运行需要 `delegate` 能力，13 §2.3），`to` 必须是小队里的托管 Agent。人类成员不能被委派运行；leader 需要人拍板时，照常写 `question`。
- `delegate_done` 的时机：委派的运行成功结束，或失败且不会自动重试，或被停止而不是人请求的（人停止就是在接管）；任务已结束、改派或小队停用时不唤醒。唤醒的是小队**当前**的 leader（`add-squads` 决策 9）。
- **授权**：委派和拆分（在运行里建子任务并指派给成员）都是 Agent 引起的新发起，授权来源继承 leader 所在运行的授权来源（13 §2.2），并按它校验能否触发目标成员。不满足时（例如指派之后小队里加入了别人的 `owner_only` Agent）`delegate` 返回 `cannot_invoke`，拆分出的子任务照常保存但不产生运行。
- 防循环规则（13 §7）同样适用：委派是 Agent 引起的新发起，成员运行的触发链包含 leader。
- **编排**（`improve-squad-leader-orchestration`）：以小队 S 身份的运行有一个**编排根**——运行的任务（执行方是 S 时）、或它所属的执行方是 S 的 Epic、或 S 为某个根建的不挂 Epic 的任务记下的根（`task_grants.root_task_id`；任务的 Epic 一有变化就清除）。**编排范围** = 根的 Epic 步骤 + 根引用为该根的任务；每次写入时在锁内重算，不跨到别的 Epic，摘下的步骤即离开（它的回调照常，但不再带编排权），根本身不是编排目标。有编排根的运行有 `orchestrate` 能力（13 §2.3），只能做三类写入：`update_task` 只改 `assignee`（空或 S 的成员；原执行方须为空、S、leader、成员或已停用 / 归档的 Agent——不能把别人手上的活拿走）与 `start`；`start_task(task_id, instructions?)` 为执行方（托管成员）开工（一次由编排发起的指派，受依赖约束）；`link_tasks` / `unlink_tasks` 两端都在范围内的 `depends_on`。不能迁移它们、写它们的 Feedback、改其它字段或建 `replaces`。每次编排写入在目标任务上由系统身份留一条备注（谁、哪次运行、做了什么、派发结果）。所以被子任务回调唤醒的 leader（运行的任务是子任务）也能启动 / 改派 / 排序父 Epic 的其它步骤。
- **停滞唤醒**：执行方是 S、IN_PROGRESS、无待回答、未被阻塞的 Epic，Epic 与步骤上都没有进行中的运行，且有闲置步骤（无人或托管执行方、该步骤上没有任何运行、没有待回答——执行方是人、被依赖延后的步骤不算）时，唤醒当前 leader（`epic_stalled`，任务为 Epic，以 S 身份，授权继承「Epic × S」的指派授权）。检查是 Oban 任务：运行终态、Epic 或步骤迁移、人在 Epic 或步骤上写 Feedback 之后延迟 120 秒，加上依赖清扫兜底（按 `epic_watch_checks` 的最近检查时间轮转，每个候选在有界次数的清扫内被检查），不另设调度器。去重以**进展周期**为单位（步骤完成、人在 Epic / 步骤上迁移或写 Feedback 开启新周期；系统与 Agent 的 Feedback 不算）：同一周期内签名（闲置步骤及其状态、执行方、最近运行）没变不再叫、最多连续 3 次，之后在 Epic 上写一条系统备注请人处理；两次唤醒至少间隔 15 分钟。这些都按 `epic_watch_checks` 记下的**唤醒**（成功入队、并入或延后的那一次）计算，不按运行里的触发记录——重试复制的触发不会多计。领取时 Epic 已不停滞则丢弃。
- **对 leader 本人的提及与手动运行**：被 @ 或被人手动运行的托管 Agent 是某个未停用小队 S 的 leader，任务的执行方是 S 或任务所属 Epic 的执行方是 S（都成立且不同则取任务的执行方；leader 带的其它小队不参与），且触发者能触发 S（§1.1）→ 以 S 身份运行（得到 `delegate` 与 `orchestrate`）；不能触发 S → 以 Agent 本人运行，提示词说明原因。@leader 因此不会比 @小队拿到更多权力。直接指派给 leader 本人的任务不升级（指派绑定执行方，且那表示 leader 自己做）。
- **规格流程**（17 §5，`add-spec-workflow`）：任务有未定稿的规格（含空规格）时，leader 先用 `delegate(…, spec: "draft" | "review" | "revise")` 安排起草、评审（可以请人类成员，只建评审请求）、修订，用 `rule_spec_issue` 裁定分歧，门槛满足后 `finalize_spec` 附评审汇总；定稿前不安排实现，定稿后照常委派或拆分实现。人交了 leader 请求的评审、人批准 / 退回定稿时，leader 被 `spec_reviewed` / `spec_decided` 唤醒（13 §2.1）。

### 1.4 对话创建小队

在 12 §6 的创建对话上加小队（`add-agent-conversation` 决策 15 定接口，`add-squads` 落地）：对话种类 `squad`；草稿除新 Agent 外还有 `squad`（名字、描述、leader、说明、成员与 `role_note`），leader 与成员可以是草稿里的新 Agent 或工作区已有的身份；起草 Agent 用 `propose_squad` 写小队部分，草稿与提示词里给出「能触发这个小队的成员 N / M」（§1.1 的保存时提示）。确认时在一个事务里先建新 Agent、再建小队与成员，全部成功才提交；创建权限同 §1.1（admin 以上或 leader 的所属用户——leader 是草稿里的新 Agent 时就是确认的人）。

### 1.3 和验收、合并的关系

自动合并要求验收独立于代码的出处（15 §4.1）。放到小队里：

- **父任务**：小队本身、leader 和所有成员都不独立（按验收时记下的名单与对账时的名单的并集，事后移出成员不会让旧验收变独立，15 §4.1）。小队内部的人或 Agent 验收父任务算自验收（05 §5）：要带通过的测试，且不触发自动合并。否则 leader 让自己的评审成员点 VERIFIED，代码就能不经外部验收进入主分支。父任务应由小队外的提出方验收。
- **拆分出的子任务**：成员的运行是 leader 引起的，leader 在出处里，所以 leader 验收子任务同样不触发自动合并，子任务的 PR 需要外部验收或手动合并。这就是上面推荐「改代码优先用委派」的原因：委派让全部改动落在父任务的一个 PR 里，只需要外部验收一次。

## 2. 自动化

> 按计划、手动或 webhook 触发一个 Agent 去做预设的工作，例如每天整理新任务、每周升级依赖、CI 夜间失败时排查。规格见 `add-autopilots`。

### 2.1 模型

| 表 | 列 |
|---|---|
| `autopilots` | `workspace_id`、`name`、`agent_id`（目标：托管 Agent；建任务模式也可以是小队）、`project_id`（可空，建任务模式必填）、`mode`、`title_template`、`instructions`（≤ 16 KB）、`create_tasks`（仅运行模式的能力）、`cron`（可空）、`timezone`、`overlap`（`skip` 缺省 \| `queue`）、`enabled`、`next_run_at`、`webhook_token_hash`（可空）、`initiator_user_id`（授权来源，§2.5）、`created_by_user_id`、`disabled_reason`、`consecutive_failures`、`lock_version`、时间戳 |
| `autopilot_runs` | 一次触发一行：`autopilot_id`、`source`（`schedule` \| `manual` \| `webhook`）、`scheduled_for`、`delivery_id`、`initiator_user_id`、`note`（手动附加说明）、`payload jsonb`（webhook 请求体，≤ 64 KB）、`config jsonb`（接受请求时冻结的执行配置）、`task_id`、`run_id`、`status`（`pending` \| `skipped` \| `started` \| `succeeded` \| `failed` \| `cancelled`）、`reason`、`result`、`started_at`、`finished_at` |

### 2.2 两种模式

| 模式 | 做什么 | 结果在哪 |
|---|---|---|
| `create_task` | 以这次触发的授权来源（§2.5）的身份在 `project` 里建一张任务：标题来自模板（支持 `{{date}}` `{{source}}`），正文是 `instructions` + 触发信息（手动说明、webhook 内容前 4 KB，标为不可信数据），执行方是目标（Agent 或小队），标签 `autopilot`，提出方是授权来源本人。之后完全按普通任务走：指派触发、分支、PR、验收、合并 | 那张任务 |
| `run_only` | 不建任务，直接为 Agent 建一次运行（`task_id` 为空，触发 `autopilot`），提示词是 `instructions` + 触发来源 + 手动说明 + payload（≤ 32 KB，标为不可信数据）。项目绑定了仓库时在基础分支的临时只读检出里跑（14 §7），**不推送**任何改动，结束即删除 | `autopilot_runs.result`（Agent 的最后输出）；勾选 `create_tasks` 时 Agent 也可以通过 MCP 建任务，但不能写任何已有任务 |

`run_only` 适合「看一看然后建工单」这类工作；要改代码就用 `create_task`，这样改动有任务、有 PR、有验收。

### 2.3 调度、重叠与结算

- 保存时用 `crontab` 库按时区（`tz` 时区库）算出 `next_run_at`（标准 5 段；相邻两次至少 5 分钟；夏令时跳过的本地时刻取跳变后的第一个时刻，回拨时只取较早的一次），并插入一个 Oban 任务 `AutopilotFire`，`scheduled_at = next_run_at`，按 `(autopilot_id, next_run_at)` 唯一；配置改变后旧任务执行时发现时刻不符，什么都不做。
- 触发时（定时、手动、webhook 都一样）以授权来源的身份开写事务，锁住这条自动化（全序里在成员关系行之后、图锁之前，01 §4），先就地结算上一次，再看是否还有在进行的。`autopilot_runs` 上的部分唯一索引 `(autopilot_id) WHERE status = 'started'` / `'pending'` 兜底：
  - `skip`：记一条 `skipped`；
  - `queue`：记一条 `pending`；上一次结算后执行它；
  - 新请求一律取代已有的 `pending`（改为 `skipped`，最新的请求胜出），所以旧请求不会排在新请求之后执行；
  - 否则直接执行；定时触发再算下一次时间，插入下一个 `AutopilotFire`。
- **结算**（一次执行何时算结束）：`run_only` 随运行结束（成功 / 失败 / 被人停止 → `cancelled`）；`create_task` 在任务 DONE 或 VERIFIED 时成功（之后的验收、打回、合并属于普通任务流程，不再占住自动化），REJECTED 失败，CANCELLED 或改派给别人时 `cancelled`，任务上的运行失败且不会再自动重试时失败；运行成功结束而任务还在进行（例如在等回答）仍算在进行。运行结束、任务迁移、改派、下一次触发和对账时都会结算。
- 服务停机错过的时间：迟到 1 小时内只补触发一次，超过 1 小时记一条 `skipped`（`missed`）；都从当前时刻算下一次，不会在恢复时连续补跑。
- 启动时与每 10 分钟有一个对账任务，确保每个启用的自动化都有一个排好的 `AutopilotFire`，并结算在进行的记录。

### 2.4 触发方式

- **定时**：cron 表达式 + 时区，界面上用人话预览（「每个工作日 09:00（Asia/Shanghai）」）和接下来 5 次的时间。
- **手动**：自动化页面上的「立即运行」，可以临时附加一段说明（≤ 4 KB）；停用的自动化也能立即运行（试运行，成功不自动启用）。
- **Webhook**：`POST /hooks/autopilots/:id`，请求头 `Authorization: Bearer hma_…`，请求体作为 payload（≤ 1 MB，保存时截断到 64 KB）。鉴权通过后按自动化限流，每分钟 10 次。响应：新触发 202、重复投递 200、id 不存在或令牌不对一律 401（不暴露 id 是否存在）、自动化停用 409、超限 413 / 429。
- Webhook 令牌是 32 字节随机数（前缀 `hma_`），只存哈希，开启与轮换时显示一次，可以随时轮换；请求带 `X-Delivery-Id` 时按它去重（同一自动化内永久；带投递 ID 的记录不清理，没有投递 ID 的跳过记录 30 天后清理），重复投递不会重复触发。

### 2.5 权限与失败

- 创建 / 修改 / 启用 / 立即运行 / 开启或轮换 webhook：有权触发目标的成员（Agent 按 12 §2.1，小队按 §1.1）；owner / admin 也不能绕过 `owner_only`。停用、删除：另允许 admin 以上（关掉别人失控的自动化）。Agent 身份一律不能管理（管理类动作）。
- **授权来源 = 最后一次保存它的人**（建、改、启用、开启或轮换 webhook 的人；停用、删除不改）。定时和 webhook 触发以它为授权来源；手动触发的是点按钮的人（他也必须有权触发目标）。这样别人改了你的自动化，运行就以他的名义进行，不能借你的授权触发他无权触发的 Agent。每次触发的记录冻结接受时的执行配置（模式、目标、项目、说明等），排队、执行、结算都按它；改了执行配置时排队的请求作废（`config_changed`），所以排队的请求永远只以自己的发起人执行自己接受时的配置。
- 授权来源离开工作区时，他的自动化在同一事务里停用；失去触发权限、目标被归档、项目被归档时，下一次触发记失败并停用。停用原因显示在页面上。
- 自动化建出的运行能力范围（13 §2.3）：`create_task` 模式同普通任务；`run_only` 模式没有任务可写，只有 `read`，外加在自动化配置里勾选的 `create_tasks`。
- `run_only` 的运行**不自动重试**、也不能人工重试（要再跑就「立即运行」，结果才有记录），避免和下一次计划执行重叠；`create_task` 建出的任务按普通运行的规则重试（13 §5）。
- 连续失败 5 次自动停用，等人检查；重叠跳过和人为取消不计入、也不打断计数，成功一次归零。

## 3. 界面

- `/w/:slug/squads`：小队列表与编辑（leader、成员、说明）。
- `/w/:slug/autopilots`：列表（下次时间、最近结果、启用开关）；详情页是配置和触发历史，每一条链到对应的任务或运行记录。
- 指派选择器里人、Agent、小队分组显示；无权触发的 Agent 和小队（§1.1）置灰并说明原因。

## Context

接口以 `openspec/changes/add-agents-runs-ui/reviews/domain-request-1.md` 的 R1、R5–R10 为准（签名、返回形状、授权动作）；本设计只补齐它没定的细节。依据 12 §2–§3、13 §1、§2.2、§4。前置：`add-run-dispatch`（`Runs.enqueue/3` 第 1–2 步、`Agents.trigger_check/3`、`Origin.from_scope/1`）、`add-run-lifecycle`（运行列、`Runs.summary/1`、`:view_runs`）、`add-agent-profiles-runtimes`（`Agents` 视图、`Daemons.list_own/1`、`MarkOffline`）。

## Goals / Non-Goals

**Goals:** 界面一次渲染所需的读取都是固定次数的查询，不按 Agent、任务逐条查；权限规则与 `Policy` 只有一份。

**Non-Goals:** 写操作；缓存；改表结构。

## Decisions

### 决策记录

1. **归属**（hm-architect）：单独的后端变更 #45，hm-coder 实现，排在 #19 之后、#22 收尾之前。不并入 #22：00 §9.4 规定领域函数由后端变更交付，前端分支不改 `server/lib/helmsman/`。
2. **R1 `Dispatch.availability(scope)`**：`:read_tasks`。取工作区内托管、未归档的 Agent 及其 actor、配置、运行时、守护进程（一条带 join 的查询），所属用户的成员关系与 `access_member_ids` 判定在内存里按 `Agents.trigger_check/3` 的同一纯函数做（把它的判定部分抽成不查库的 `Agents.TriggerRule.check/3`，`trigger_check/3` 改为调用它，规则只有一份）。顺序：`agent_disabled` / `unauthorized` → `no_runtime`（未绑定）→ `runtime_disabled`；运行时离线仍是 `:ok`（`runtime.status = "offline"`）。不做防循环与频率检查。结果只是提示：真正入队时 `enqueue/3` 照常复核。查询不超过 3 条。
3. **R5 `Runs.active_agents(scope, idents)`**：`:view_runs`；`idents` 最多 200 个（超出 → `{:error, :too_many}`），不存在的 ident 忽略；一条查询（`tasks` join `runs` join `actors`，`status IN ('claimed','running','cancelling')`，按 `claimed_at` 升序、同一任务内 Agent 名去重）。
4. **R6 `Runs.usage_for_agent(scope, name, days: 30)`**：`:view_runs`；`days` 为 1–90（否则 `{:error, :invalid_days}`）；Agent 不存在或是外接 Agent → `:not_found`（已归档的照常可查）；先按名字取 Agent（判定存在），再做聚合，所以「有这个 Agent 但区间内没有运行」返回全 0 的 `days` 与 `totals.runs = 0`，不会被当成不存在。只统计终态运行，`finished_at` 落在 `[今天(UTC) − (days − 1), 今天]`；每天的 `succeeded` / `failed` / `cancelled` 计数，`input_tokens` / `output_tokens` 为 `usage` 里对应键的和（`null` 当 0），`cost_usd` 为和，当天全部为 `null` 时为 `nil`；`totals.runs` = 区间内终态运行数。一条 `GROUP BY` 查询，缺的天在 Elixir 里补 0。
5. **R7**：`last_run_at` = 该 Agent 最近一条运行的 `inserted_at`（与 `active_runs`、`queued_runs` 在同一个聚合查询里）。Agent 视图另加非敏感的 `workspace_id` 与 `actor_id`（规格评审 1 P2：同一用户可以在两个工作区有同名 Agent，视图里没有来源就无法做 `Policy` 的工作区隔离检查）。`Agents.permissions(scope, view)` 纯函数：用视图的 `actor_id`、`workspace_id`、`owner.id` 构造最小的 `%Actor{kind: :agent}`，对 `:configure_agent` / `:administer_agent` 调用与 `Policy.authorize/3` **同一个**不查库的检查（含 `in_workspace?` 与运行 scope 恒为假）。不另写规则，也不假设调用者总传本工作区的视图：跨工作区的视图恒为假。#22 的 `RunData` 照此视图形状（`add-agents-runs-ui/reviews/domain-request-1.md` R7 已同步）。
6. **R8**：`Daemons.online_threshold_seconds/0`（120）作为唯一定义，`MarkOffline` 与 `list_own/1` 都用它；`online` = 未吊销且 `last_seen_at > now − 阈值`。
7. **测试**：查询次数用 `Ecto` 的 telemetry 事件计数断言（`[:helmsman, :repo, :query]`），每个函数断言在 1 个与 20 个 Agent / 任务时查询数相同，并同时断言返回内容正确（不能只满足查询次数）。R6 的「先取 Agent 再聚合」是 2 条查询，固定不变。
8. **R9 `Runs.list_open(scope, {:task, ident} | {:agent, name}, opts)`、R10 `Runs.list_finished/3`**（#22 规格评审 1 之后追加，hm-architect 确认归本变更）。都是 `:view_runs`；任务或托管 Agent 不存在 → `:not_found`；`opts` 不合法（游标形状不对、`limit` 超界）→ `{:error, :invalid_opts}`。摘要用 `Runs.summary/1` 的批量形式（#19 / R2），不逐条查询。
   - R9：`active` = 全部 `claimed | running | cancelling`，按 `(claimed_at, id)`，不分页、不截断（通常任务最多 1 条、Agent 不超过 `max_concurrency`；即使实际超过当前并发配置，例如并发调低之前已领取的运行，也全部返回）；`pending` = `queued | deferred`，按 `(priority DESC, inserted_at, id)`（与领取的排序一致，`not_before` 只是领取时的过滤条件，不参与显示顺序），`pending_limit` 缺省 50、1–200，`pending_after: {priority, inserted_at, id}` 为严格在其后的游标；`pending_total` 为排队与延后的总数。查询：活跃 1 条、排队一页 1 条、排队计数 1 条，再加摘要批量查询，与条数无关。
   - R10：只含 `succeeded | failed | cancelled`，按 `(inserted_at DESC, id DESC)`；`limit` 缺省 50、1–100；`before: {inserted_at, id}` 为严格在其前的游标；`total` 为终态总数（1 条 `count`）。
   - 游标按元组比较（`(priority, inserted_at, id)` 的行值比较，`priority` 降序时取反）。跨调用的保证见决策 9。
9. **分页语义的最终裁定**（规格评审 2，hm-architect；不再开第三轮）。`priority` 会在合并触发时升高（13 §3），R10 的新终态行可能落在游标任一侧，所以不承诺跨调用、跨变化的游标稳定：
   - **R9 `{:task, ident}`**：`pending` **完整返回**，不分页（`pending_limit`、`pending_after` 对任务目标忽略），按领取顺序排列；`pending_total` 等于其长度。依据：排队与延后的运行在 `(task_id, agent_id, lane)` 上唯一（`add-run-dispatch` 的部分唯一索引 `runs_pending_index`，`add-squads` 再加小队），数量受「Agent × lane（× 小队）」约束，不随历史增长。这比分页更强，#22 D8 的循环读取在第一次调用后就会结束。
   - **R9 `{:agent, name}` 与 R10**：只保证**单次调用**的正确性：返回的是调用时、按当前顺序排在游标之后（R10 为之前）的那一页，总数是调用时的精确值。两次调用之间若有运行变化（优先级升高、新排队、新结束、状态变化），沿用旧游标可能重复或遗漏这些行；没有变化时连续翻页不重复、不遗漏。需要一致视图的调用方在收到运行变化通知后**从第一页重读**到已显示的条数（#22 D8a 的「可重置读取」），总数也只取自读取结果。R10 的排序键 `(inserted_at, id)` 不变，已有的终态行不会移动。
   - 规格的「未结束的运行」「已结束的运行」两个场景据此改写，并增加优先级升高后重读的场景。
   - 评审 2 的非阻断 P3（tasks 1.3 查询数）：按决策 7 固定为 2 条，tasks 已改。#22 的 `domain-request-1.md` R9 / R10 行与「处理状态」同步本决策。回复见 `reviews/spec-reply-2.md`。
## Risks / Trade-offs

- [可用性提示与实际入队之间状态变化] → 只是提示，入队时复核（决策 2）。

## Migration Plan

无。

## 1. 实现（hm-coder；前置：#17、#18、#19 已合并）

- [x] 1.1 R1 `Dispatch.availability/1` 与 `Agents.TriggerRule.check/3`（决策 2）。验证：`test/helmsman/dispatch/availability_test.exs` 覆盖「Agent 的可派发性」两个场景；另加：停用、未绑定、运行时禁用、已归档不出现、外接 Agent 不出现；与 `Agents.trigger_check/3` 对同一组输入表驱动比较结果相同；1 个与 20 个 Agent 时查询数相同且 ≤ 3
- [x] 1.2 R5 `Runs.active_agents/2`（决策 3）。验证：`active_agents_test.exs` 覆盖场景；另加：超过 200 个 → `:too_many`；同一任务两条运行按领取先后、Agent 去重；查询数为 1；没有 `:view_runs` 的 scope → `:forbidden`
- [x] 1.3 R6 `Runs.usage_for_agent/3`（决策 4）。验证：`usage_for_agent_test.exs` 覆盖场景；另加：存在但区间内没有运行 → 全 0、不是 `:not_found`；`days` 为 0 或 91 → `:invalid_days`；外接 Agent → `:not_found`；跨 UTC 午夜的 `finished_at` 落到正确的天；费用全为 `null` 的天为 `nil`、有一条有值时为和；查询数固定为 2（先取 Agent、再聚合）且内容正确
- [x] 1.4 R7 `last_run_at`、视图的 `workspace_id` / `actor_id` 与 `Agents.permissions/2`（决策 5）。验证：`agents_views_test.exs`：`last_run_at` 正确、列表 1 与 20 个 Agent 查询数相同且内容正确；规格「权限与授权检查一致」场景按角色表驱动（含运行 scope 恒为假）；「跨工作区的视图」场景：两个工作区、同一用户、同名 Agent，scope × 视图四种组合表驱动，与 `Policy.authorize/3` 对相应 actor 的结果逐一相同，跨工作区恒为假
- [x] 1.5 R8 `online` 与 `Daemons.online_threshold_seconds/0`（决策 6）。验证：规格场景；`MarkOffline` 与 `list_own/1` 都引用该函数（`grep` 不到别处的 120 / 2 分钟常量）
- [x] 1.6 R9 `Runs.list_open/3`、R10 `Runs.list_finished/3`（决策 8）。验证：`list_open_test.exs`、`list_finished_test.exs` 覆盖「未结束的运行」三个场景与「已结束的运行」场景（决策 9：任务目标的排队完整返回且忽略分页选项；优先级升高与晚结束的旧运行都用「第一页之后改数据、再从第一页重读」断言每条恰好一次），任务与 Agent 两种目标都测；另加：不存在 → `:not_found`、`limit` 越界或游标形状不对 → `:invalid_opts`、无 `:view_runs` → `:forbidden`；1 条与 50 条运行时查询数相同且内容正确；`pending` 同优先级按入队先后、`deferred` 与 `queued` 一起计数
- [x] 1.7 `cd server && mix precommit` 通过；在 `add-agents-runs-ui/reviews/domain-request-1.md`「处理状态」里标记 R1、R5–R10 已交付

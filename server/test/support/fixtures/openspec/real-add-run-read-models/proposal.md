## Why

界面变更 `add-agents-runs-ui`（#22）需要几个只读的领域函数（`reviews/domain-request-1.md` 的 R1、R5–R8）。它们不属于 `add-run-lifecycle`（#19，已随它做了 R2–R4），而 00 §9.4 规定后端与界面分开：领域函数由后端变更交付。所以单独一个小的后端变更，界面在它合并前用 `HelmsmanWeb.RunData` 的占位实现。

## What Changes

- `Helmsman.Dispatch.availability/1`（R1）：工作区里每个托管、未归档 Agent 在当前用户发起时能否被派发，以及它绑定的运行时。
- `Helmsman.Runs.active_agents/2`（R5）：一批任务各自正在运行的 Agent。
- `Helmsman.Runs.usage_for_agent/3`（R6）：Agent 最近 N 天按日的运行数与用量。
- `Agents.list/1`、`get/2` 的视图加 `last_run_at`；`Agents.permissions/2`（R7）。
- `Daemons.list_own/1` 每项加 `online`，在线阈值只定义一处（R8）。
- `Runs.list_open/3`（R9：全部活跃运行 + 排队分页与总数）、`Runs.list_finished/3`（R10：已结束运行分页与总数）。
- 不改表结构、不改已批准规格的行为。

## Capabilities

### New Capabilities

- `run-read-models`：上述五个只读接口的结果、授权与查询次数约束。

### Modified Capabilities

（无）

## Impact

- 只改 `server/lib/helmsman/`（`dispatch`、`runs`、`agents`、`daemons`、`policy`）与测试；hm-coder 实现。
- 依赖：#17 `add-agent-profiles-runtimes`、#18 `add-run-dispatch`、#19 `add-run-lifecycle`（运行的 `claimed_at`、`finished_at`、`usage` 等列）都合并之后实现。
- `add-agents-runs-ui`（#22）的 tasks 4.5、4.7 依赖本变更；R1、R7、R8 的占位实现在本变更合并后改为直接委托（其 tasks 5.2）。
- designs/00 §9 增加 #45，#22 的依赖加 45。

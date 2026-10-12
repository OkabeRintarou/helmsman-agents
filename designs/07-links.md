# 07 · 任务关联

> 对应 bosun 的 12，语义不变。关联可以跨项目，但不能跨工作区。

## 1. 类型

两种有方向的关联。不做「相关」这种没有语义的链——需要时在 Feedback 里引用 ID 即可。

| 类型 | A → B | 效果 |
|---|---|---|
| `replaces` 替代 | A 接手 B 的内容 | 建链时 B 若在 NEW / IN_PROGRESS，自动 → CANCELLED（`auto`，备注 `replaced by A`）；B 在其他状态只记链。链存在期间 B 不能从 CANCELLED 恢复（`{:replaced, [A]}`），要恢复先删链 |
| `depends_on` 依赖 | B 没做完 A 不能开始 | B 不满足（§3）→ A `blocked = true`；A 从 NEW → IN_PROGRESS 被拒 `{:blocked, [B, …]}`。其他迁移不拦：已经在做的不会因新加依赖而停，打回 / 重开也不拦 |

## 2. 规则

- 两端存在且在同一工作区；不能自链；同一对可以同时有两种类型；重复添加是幂等的。
- `depends_on` 不能成环：加 A → B 之前，用递归 CTE 从 B 沿 depends_on 往下走，能走到 A 就拒绝 `{:cycle, [A, B, …, A]}`。
  建 / 删链都在工作区图锁里进行（01 §4），两个并发请求不会合起来成环。

```sql
WITH RECURSIVE reach(id, path) AS (
  SELECT to_task_id, ARRAY[from_task_id, to_task_id]
    FROM task_links WHERE from_task_id = $b AND type = 'depends_on'
  UNION ALL
  SELECT l.to_task_id, r.path || l.to_task_id
    FROM task_links l JOIN reach r ON l.from_task_id = r.id
   WHERE l.type = 'depends_on' AND NOT l.to_task_id = ANY(r.path)
)
SELECT path FROM reach WHERE id = $a LIMIT 1;
```

- 删链允许（不是审计记录），删链不改任何状态（删掉 `replaces` 链后，被撤销的任务仍是 CANCELLED，需要的话再手动恢复）。任务不能删，所以链不需要级联删除。
- **与派发的关系**：指派给托管 Agent 的任务被阻塞时，运行以 `deferred` 状态等待；依赖全部满足时自动开始排队（13 §2.4）。删掉最后一条未满足的依赖链也会让它开始排队。

## 3. 派生字段

- **依赖满足**（只在一处定义，`Helmsman.Links.satisfied?/1`，`blocked`、迁移检查、BQL、派发都用它）：
  - 前置任务所在项目**绑定了仓库**、且这个任务有 PR → 要求 PR **已合并**。只到 DONE / VERIFIED 不够：后一个任务的分支从基础分支建出，此时还拿不到前一个任务的代码。
  - 前置任务所在项目绑定了**本地仓库**、且这个任务交付过分支（有 `task_local_branches` 行）→ 要求该分支**已合并**（守护进程检测到它已进入基础分支，或人工标记，15 §8），理由同上。
  - 其他情况（项目没绑仓库、任务没产生代码改动）→ 前置任务在 DONE / VERIFIED。
  - 这与 bosun 的语义（只看 DONE / VERIFIED）在代码任务上有意不同。
- `blocked`：存在出向 `depends_on` 且对端不满足。列表一次查询用 `EXISTS` 子查询算出，不落库。
- `links`（详情）：`[%{type, direction: :out | :in, task, title, status, kind, actor, created_at}]`，出链在前，再按类型、ID 排序。

## 4. 广播

建 / 删链后，两端任务各发 `task:<id>` `{:links_changed}`；对端被自动撤销时额外走 05 §7 的迁移广播。

## 5. 接口

- 领域：`Helmsman.Links.add(scope, from, to, type)` / `remove(scope, from, to, type)` → from 的详情；`blockers(task)`。
- MCP：`link_tasks(from, to, type)`、`unlink_tasks(from, to, type)`；被阻塞时 `transition_task` 的错误文本列出阻塞任务，并提示可以 `unlink_tasks`。
- REST：`POST /api/v1/w/:slug/tasks/:id/links {to, type}` → 201；`DELETE /api/v1/w/:slug/tasks/:id/links/:type/:to` → 200；409 `cycle`（`detail.path`）。
- BQL：`blocked`、`depends_on`、`blocks`、`replaces`、`replaced_by`（见 10）。

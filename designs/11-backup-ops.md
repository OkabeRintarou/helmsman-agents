# 11 · 导出导入、REST 与运维

## 1. 导出 / 导入

> 对应 bosun 的 10。粒度从「整库」变成「一个工作区」。

### 1.1 格式

```json
{
  "format": "helmsman-export", "version": 1, "exported_at": "...",
  "workspace": {"slug": "...", "name": "..."},
  "actors": [...], "projects": [...], "tasks": [...], "task_events": [...],
  "feedback": [...], "links": [...], "saved_filters": [...]
}
```

- 引用一律用对外 ID（actor 名、`KEY-N`、`KEY-N#M`），不出现数据库主键，所以能导进另一个实例或另一个工作区。
- 事件按任务内的顺序号 `n` 标识（第 n 次迁移）。
- 不导出：用户账号、成员关系、Token、检索列（导入时重算）、**私有筛选器**（它属于某个用户，而用户不导出）；共享筛选器导出时带上作者的 actor 名，仅供参考。
- 也不导出执行相关的数据：Agent 配置（含加密的环境变量）、守护进程与运行时、运行与执行记录、小队、自动化、GitHub 安装与 PR。它们绑定具体的机器、仓库和账号，换个实例没有意义；Agent 和小队作为 actor 名字保留在历史里。
- 导出在 `REPEATABLE READ, READ ONLY` 事务里读，所有表来自同一个快照，不会出现「任务状态变了、事件还没有」这种半截数据。
- 导出可能很大：用 Oban 任务在后台生成文件，完成后在页面上给下载链接（保留 24 小时）。`mix helmsman.export --workspace acme` 直接写文件。

### 1.2 导入

| 模式 | 行为 | 权限 |
|---|---|---|
| `merge`（缺省） | 按任务「快进」合并，见下 | admin |
| `replace` | 先清空该工作区的任务域数据再写入。要求该工作区没有 `claimed` / `running` 的运行；排队中的运行一并取消，运行记录与 PR 关联随任务一起清掉 | owner |

- 整个导入一个事务，并拿工作区**维护锁的排他模式**（01 §4）：导入期间该工作区的其他写入全部等待，结果不会混入并发写。
  任一条不合法整体回滚，返回出错的记录位置。
- 每次导入在 `imports` 表记一条（谁、何时、模式、来源、文件哈希、各类条数），`replace` 还会在界面上二次确认。

**merge 不改写已有的历史。** 事件和 Feedback 是只追加的审计记录，所以按任务逐个比较：

| 本地 vs 导入文件（同一任务） | 结果 |
|---|---|
| 本地没有这个任务 | 整个插入 |
| 本地的事件、Feedback 是文件的**前缀**（文件更新） | 快进：补上缺的事件和 Feedback，任务字段取文件里的；Feedback 的作废标记只会从 active 变成 superseded，不会反过来 |
| 文件是本地的前缀（文件更旧） | 跳过，报告里列为「本地较新」 |
| 两边相同 | 不动 |
| 两边分叉（同一序号内容不同） | 报错，整个导入回滚 |

项目、链、actor 这类可变数据「同 key 覆盖」；项目的 `task_seq` 取两边的较大者。
（bosun 的 merge 是同 key 直接覆盖，导入旧快照会把修订过的 Feedback 改回有效。这里不会。）

**actor 映射**：导入文件里的 actor 名——

- 本工作区已有同名、同 kind 的 actor（agent 还要求所属用户能对上，或执行导入的人是 admin）→ 直接用它；
- 已有同名但 kind 不同 → 报错，可以通过导入参数 `rename: %{"旧名" => "新名"}` 改名后再导；
- 不存在：
  - human：建一个**未认领**的 human actor（`user_id` 为空，不能登录也不能写入）；
  - agent：建 agent actor，`owner_id` = 执行导入的用户；admin 之后可以改所属用户。

**认领** = 合并：成员在设置页把某个未认领的 human 认领为自己时，在一个事务里把所有指向它的引用（任务的提出方 / 执行方、事件、Feedback、链）改指向这个成员自己的 human actor，再删掉未认领的那条。
这样不违反「每个用户在每个工作区只有一个 human actor」的唯一约束。只有 admin 能确认认领，避免有人认领别人的历史。

**筛选器**：文件里的共享筛选器导入为执行导入的用户所有、`visibility = workspace`；重名时加后缀 ` (imported)`。

### 1.3 从 bosun 迁移

`mix helmsman.import_bosun path/to/bosun-export.json --workspace acme`：读 bosun 的 `bosun-export` v2 格式，转换后走 1.2 的导入流程。

| bosun | Helmsman |
|---|---|
| `projects[]` | `projects`，`archived: true` → `archived_at = exported_at` |
| `tasks[].history`（倒序） | `task_events`（正序），`commits` / `tests` 原样保留 |
| `tasks[].epic` / `kind` | `epic_id` / `kind` |
| `feedback[]` | `feedback`，修订链按 `supersedes` / `superseded_by` 还原，`thread_seq` 取链首的 `seq` |
| `links[]` | `task_links` |
| `filters[]` | `saved_filters`，按 1.2 的筛选器规则（bosun 没有私有筛选器，全部视为共享） |
| `actor` 表 | `actors`，按 1.2 的映射规则 |
| `user`（bosun 的缺省人类名） | 执行导入的用户本人的 human actor |

## 2. REST API

LiveView 不需要 REST；REST 给脚本、CI 和不支持 MCP 的工具用，与 MCP 共用领域层。

- 前缀 `/api/v1/w/:slug`，`Authorization: Bearer hm_…`（`api:read` / `api:write` scope）；`slug` 必须是 Token 所属的工作区，否则 404。
- 资源与 bosun 的 REST 一一对应：`projects`、`projects/:key/tasks`、`tasks/:id`、`tasks/:id/transition`、`tasks/:id/feedback`、`feedback/:id`、`tasks/:id/links`、`search`、`query`、`filters`、`actors`、`export`、`import`；另有 `agents`、`runs`（13 §10）、`autopilots/:id/run`。
- 不走 `/api/v1` 的端点：守护进程 Channel `/daemon/socket`（14 §3）、设备码登录 `/api/device/*`（12 §3.1）、GitHub webhook `/webhooks/github`（15 §1）、自动化 webhook `/hooks/autopilots/:id`（16 §2.4）。
- 错误体统一 `{"error": "invalid_transition", "message": "...", "detail": {...}}`；状态码：400 参数 / 401 认证 / 403 权限 / 404 不存在 / 409 状态冲突（`invalid_transition` `blocked` `replaced` `self_verify_requires_tests` `cycle` `superseded` `stale`）/ 422 校验失败。
- `GET /api/v1/workflow.md?lang=zh|en` 不需要认证。
- 用 `open_api_spex` 生成 OpenAPI 文档，`/api/v1/openapi.json`。

## 3. 发布与运维

| 项 | 做法 |
|---|---|
| 打包 | `mix phx.gen.release --docker` 生成 `Dockerfile` 与 `Helmsman.Release`；镜像发到 GHCR。守护进程的各平台二进制随同一个版本发布（14 §1），服务端提供 `/install.sh` 和下载地址 |
| 部署 | `docker compose`（app + postgres）示例放在 `deploy/`；首次启动自动跑 migration（`Helmsman.Release.migrate/0`）。服务必须能被执行机器（守护进程 WebSocket）和 GitHub（webhook）访问到；只在内网时 GitHub 部分退化为轮询（15 §1） |
| 健康检查 | `GET /healthz`（进程存活）、`GET /readyz`（能连上数据库、Oban 在跑） |
| 观测 | `Phoenix.LiveDashboard` 挂在 `/admin/dashboard`，只有实例管理员（`users.instance_admin`）能进；Telemetry 指标可接 Prometheus（`telemetry_metrics_prometheus`），包括运行队列长度、等待时间、各失败原因的计数、在线机器数 |
| 日志 | JSON 日志（`logger_json`）；MCP 每次工具调用记一行：工作区、actor、运行 ID、工具名、耗时、结果 |
| 限流 | `/mcp` 与 `/api` 按 Token 限流（`hammer`，缺省每分钟 600 次）；登录 / magic link / 设备码按 IP 限流 |
| 数据清理 | Oban 定时任务：`run_events` 保留 30 天（按月分区整块删除）、过期的运行令牌与设备码、导出文件 24 小时 |
| 备份 | 以 `pg_dump` 为准；工作区 JSON 导出用于迁移和人工存档 |
| 安全 | Markdown 输出经 ammonia 净化（09 §4）；CSP 头只放行自身与 mermaid；所有令牌只存哈希；敏感配置用 cloak_ecto 加密；会话 Cookie `SameSite=Lax`、`Secure`；GitHub webhook 校验签名。执行机器上的隔离见 14 §9 |

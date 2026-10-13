# 11 · 导出导入、REST 与运维

## 1. 导出 / 导入

> 对应 bosun 的 10。粒度从「整库」变成「一个工作区」。实现见 `add-export-import`。

### 1.1 格式

```json
{
  "format": "helmsman-export", "version": 1, "exported_at": "...",
  "source": {"host": "...", "app_version": "..."},
  "workspace": {"slug": "...", "name": "..."},
  "actors": [...], "projects": [...], "tasks": [...], "task_events": [...],
  "feedback": [...], "links": [...], "saved_filters": [...]
}
```

- gzip 压缩的 UTF-8 JSON；字段表见 `docs/EXPORT-FORMAT.md`。
- 引用一律用对外 ID（actor 名、项目 Key、`KEY-N`、`KEY-N#M`），不出现数据库主键、用户 ID 或邮箱，所以能导进另一个实例或另一个工作区。Agent 的 `owner` 是所属用户的 human 身份名，只供参考。
- 事件按任务内的顺序号 `n` 标识（第 n 次迁移）。
- 顺序确定（身份按名字、任务按项目与编号……，对象键按字母序），同一数据两次导出只有 `exported_at` 不同。
- 不导出：用户账号、成员关系、Token、检索列与其他可重算的派生字段（反馈计数、待回答、版本号）、**私有筛选器**（它属于某个用户，而用户不导出）；共享筛选器导出时带上作者的 actor 名，仅供参考。
- 也不导出执行相关的数据：Agent 配置（含加密的环境变量）、守护进程与运行时、运行与执行记录（含 `source_run_id`、触发结果）、小队配置、自动化、GitHub 安装与 PR、本地仓库。它们绑定具体的机器、仓库和账号，换个实例没有意义；Agent 和小队作为 actor 名字保留在历史里。
- 导出在 `REPEATABLE READ, READ ONLY` 事务里流式读写，所有表来自同一个快照，不会出现「任务状态变了、事件还没有」这种半截数据。
- 只有 admin 以上能导出。导出可能很大：用 Oban 任务在后台生成文件（数据目录 `HELMSMAN_DATA_DIR`），完成后只给发起人下载，保留 24 小时；同一工作区同时只有一个进行中的导出。`mix helmsman.export --workspace acme` 直接写文件。

### 1.2 导入

| 模式 | 行为 | 权限 |
|---|---|---|
| `merge`（缺省） | 按任务「快进」合并，只增不删，见下 | admin |
| `replace` | 先清空该工作区的任务（及挂在任务上的事件、反馈、关联、授权、运行与执行记录、PR 与本地仓库交付记录）再写入。要求没有 `claimed` / `running` / `cancelling` 的任务运行、没有草稿 / 打开的 PR；项目行（含 GitHub / 本地仓库绑定）、身份、筛选器保留，`task_seq` 取两边较大者；需要带上工作区 slug 作确认 | owner |

- **先校验后写入**：整份文件先校验（类型、取值、唯一、文件内引用、Epic、事件序号与最终状态、反馈修订链、`depends_on` 不成环），有错误就不写入，返回至多 100 条带位置（如 `tasks[12].title`）的错误。
- 写入是一个事务，并拿工作区**维护锁的排他模式**（01 §4，30 秒拿不到返回 `busy`）：导入期间该工作区的其他写入全部等待，领取跳过该工作区，结果不会混入并发写。写入阶段任一错误（分叉、成环）整体回滚。
- **试运行**：执行全部步骤后回滚，只给报告（各类条数、身份映射、本地较新的任务、警告），界面据此预览后再确认。
- **无副作用**：导入直接写表，不触发派发、Epic 级联、提及、GitHub 调用或系统备注；派生字段同事务重算；提交后广播一次整体刷新，并复查依赖等待中的运行。
- 每次导入（含试运行与失败的）在 `imports` 表记一条（谁、何时、模式、来源、文件哈希、状态、报告、错误）。入口：网页上传、REST（请求体即文件）、`mix helmsman.import`。

**merge 不改写已有的历史。** 事件和 Feedback 是只追加的审计记录，所以按任务逐个比较：

| 本地 vs 导入文件（同一任务） | 结果 |
|---|---|
| 本地没有这个任务 | 整个插入 |
| 本地的事件、Feedback 都是文件的**前缀**（文件更新） | 快进：补上缺的事件和 Feedback，任务字段取文件里的；Feedback 的作废标记只会从 active 变成 superseded，不会反过来 |
| 文件都是本地的前缀（文件更旧） | 跳过，报告里列为「本地较新」 |
| 两边相同 | 任务字段取 `updated_at` 较新的一边（改标题、指派等不产生事件，只能看时间）；相等不动 |
| 两边分叉（同一序号内容不同，或一边事件更长、另一边 Feedback 更长） | 报错，整个导入回滚 |

项目同 Key 时名字、描述、归档取 `updated_at` 较新的一边，`task_seq` 取两边的较大者；链只新增不删除，新增后成环则回滚；actor 见下。
（bosun 的 merge 是同 key 直接覆盖，导入旧快照会把修订过的 Feedback 改回有效。这里不会。）
已有的运行不动：状态、执行方、依赖被导入改变的任务，由领取时的复核处理（13 §4.1）。

**actor 映射**：先按导入参数 `rename: %{"旧名" => "新名"}` 改名，然后对文件里的每个 actor 名——

- 本工作区已有同名、同 kind 的 actor → 直接用它（不改它的任何字段；导入本来就要求 admin，不再另查所属用户）；
- 已有同名但 kind 不同 → 报错，可以通过 `rename` 改名后再导；
- 不存在：
  - human：建一个**未认领**的 human actor（`user_id` 为空，不能登录、不能写入、不能被指派）；
  - agent：建外接 agent actor，`owner_id` = 执行导入的用户；admin 之后可以把外接 Agent 转给真正的用户（托管 Agent 不能转）；
  - squad：建一个停用的、没有小队配置的历史身份，只用于显示；
  - system：只能是 `helmsman`，对应本地的 system actor。

**认领** = 合并：成员申请把某个未认领的 human 认领为自己，admin 批准（或 admin 直接指定给某个成员）后，在一个事务里（持维护锁的排他模式）把所有指向它的引用（任务的提出方 / 执行方、事件、Feedback 的作者与提及、链及其他引用 actor 的记录）改指向这个成员自己的 human actor，再删掉未认领的那条。
这样不违反「每个用户在每个工作区只有一个 human actor」的唯一约束。只有 admin 能确认认领，避免有人认领别人的历史。

**筛选器**：文件里的共享筛选器导入为执行导入的用户所有、`visibility = workspace`；他已有同名的：BQL 相同则跳过，不同则名字加后缀 ` (imported)`；BQL 解析不了或超过每人 100 个的上限时跳过并列入警告，不让整个导入失败。

### 1.3 从 bosun 迁移

`mix helmsman.import_bosun path/to/bosun-export.json --workspace acme --as alice@example.com`（网页与 REST 也可以选来源为 bosun）：读 bosun 的 `bosun-export` v2 格式，转换后走 1.2 的校验与导入流程。

| bosun | Helmsman |
|---|---|
| `projects[]` | `projects`，`archived: true` → `archived_at = exported_at`；毫秒时间转为 UTC 时间 |
| `tasks[].history`（倒序） | `task_events`（正序），`commits` / `tests` 原样保留 |
| `tasks[].epic` / `kind` | `epic_id` / `kind` |
| `feedback[]` | `feedback`，修订链按 `supersedes` / `superseded_by` 还原，`thread_seq` 取链首的 `seq` |
| `links[]` | `task_links` |
| `filters[]` | `saved_filters`，按 1.2 的筛选器规则（bosun 没有私有筛选器，全部视为共享） |
| `actor` 表 | `actors`，按 1.2 的映射规则 |
| `user`（bosun 的缺省人类名） | 执行导入的用户本人的 human actor（可被显式 `rename` 覆盖） |
| `counters` | 忽略（编号来自 `task_seq`） |

## 2. REST API

LiveView 不需要 REST；REST 给脚本、CI 和不支持 MCP 的工具用，与 MCP 共用领域层（`add-rest-api`）。

- 前缀 `/api/v1/w/:slug`，`Authorization: Bearer hm_…`；`GET` 要 `api:read` 或 `api:write`（写包含读），其余方法要 `api:write`，缺了 403 `insufficient_scope`。`slug` 必须是 Token 所属的工作区，否则 404。运行令牌（`hmr_`）与守护进程令牌一律 401（托管 Agent 只用 MCP）。
- **REST 是 MCP 工具的另一种传输**：有对应工具的端点参数同名、同义、同上限，成功返回 `{"data": <工具的 JSON 结果>}`，以后给工具加参数 REST 自动获得；写入身份按 03 §4 的 REST 列（`X-Helmsman-Actor` 或请求体的 `actor` / `author` → Token 缺省 Agent → 本人 human），读取时的当前身份同序（用于 `/me/tasks`、BQL `currentUser()`）；没有会话，不建会话 Agent。
- 资源与 bosun 的 REST 一一对应：`projects`、`projects/:key`、`projects/:key/tasks`、`tasks/:id`、`tasks/:id/transition`、`tasks/:id/feedback`、`tasks/:id/feedback/:seq`（单条与修订，同 bosun，避免在 URL 里编码 `#`）、`POST tasks/:id/links`、`DELETE tasks/:id/links/:type/:to`、`search`、`query`、`filters`、`filters/:id`、`filters/:id/run`、`actors`；另有 `me`、`me/tasks`、`agents`（含小队）、运行（13 §10）、`autopilots/:id/run`、`exports` / `exports/:id/download` / `imports`（§1，`add-export-import`）。端点表见 `add-rest-api` 决策 6。
- 不走 `/api/v1` 的端点：守护进程 Channel `/daemon/socket`（14 §3）、设备码登录 `/daemon/device/*`（12 §3.1）、GitHub webhook `/webhooks/github`（15 §1）、自动化 webhook `/hooks/autopilots/:id`（16 §2.4）。
- 错误体统一 `{"error": "<稳定的错误码>", "message": "...", "detail": {...}}`，由 `HelmsmanWeb.ErrorMapper` 映射：400 参数（`invalid_params` / `invalid_json`）/ 401 认证 / 403 权限（`forbidden` `insufficient_scope` `agent_disabled`）/ 404 不存在 / 409 状态冲突（`invalid_transition` `blocked` `replaced` `self_verify_requires_tests` `cycle` `superseded` `stale` `busy` `project_archived` `run_active` `not_dispatched` 等）/ 413 请求体过大 / 415 不是 JSON / 422 校验失败（`validation_failed`、`invalid_bql` 等）/ 429 限流 / 500 `internal`（只给引用号，细节进日志）。`/api` 下未知路径也返回 404 的同一错误体。
- `GET /api/v1/workflow.md?lang=en|zh`（缺省 `en`）与 `GET /api/v1/openapi.json` 不需要认证，按 IP 限流。
- 用 `open_api_spex` 生成 OpenAPI 文档：工具端点的参数 schema 由工具的参数定义生成，响应 schema 在测试里逐端点断言；测试保证每个 `/api/v1` 路由都有文档。

## 3. 发布与运维

| 项 | 做法 |
|---|---|
| 打包 | 仓库根 `VERSION` 是三个项目与镜像、守护进程的统一版本；仓库根的多阶段 `Dockerfile`（构建上下文含 `protocol/`）+ `mix release`、`Helmsman.Release`；镜像（amd64 / arm64 原生构建）发到 GHCR，内含同版本的四个守护进程二进制（14 §1），服务端提供 `/install.sh` 和 `/downloads/daemon/<target>`；打 `v*` 标签触发发布工作流（`add-release-distribution`） |
| 部署 | `docker compose`（app + postgres）示例与 `.env.example` 放在 `deploy/`，步骤见 `docs/DEPLOY.md`；容器每次启动先跑 migration（`bin/start` → `bin/migrate`，迁移用 advisory lock，失败则不启动）。反向代理后设 `HELMSMAN_TRUSTED_PROXIES`。服务必须能被执行机器（守护进程 WebSocket）和 GitHub（webhook）访问到；只在内网时 GitHub 部分退化为轮询（15 §1）。发布包里没有 mix，管理命令用 `bin/server eval "Helmsman.Release.…"`（迁移、重建索引、引导、导出 / 导入） |
| 健康检查 | `GET /healthz`（进程存活，不碰数据库）、`GET /readyz`（2 秒内能查数据库、Oban 在跑；失败 503 并列出失败项，不带细节）；不需认证、不进日志 |
| 观测 | `Phoenix.LiveDashboard` 挂在 `/admin/dashboard`，只有实例管理员（`users.instance_admin`）能进，其他人 404；Telemetry 指标：排队运行数、领取等待时间、按状态与失败原因的结束计数、在线机器数、MCP 工具调用耗时（不带工作区名与内容）。接 Prometheus（`telemetry_metrics_prometheus`）留作以后 |
| 日志 | JSON 日志（`logger_json`，`HELMSMAN_LOG_FORMAT`），元数据白名单（请求 ID、工作区、Token、运行、守护进程）；MCP 每次工具调用记一行：工作区、actor、运行 ID、工具名、耗时、结果类别（不记参数与内容）；令牌与密钥不进日志 |
| 限流 | `/mcp` 与 `/api` 按 Token 限流（`hammer`，缺省每分钟 600 次，同一 Token 两边共用额度）；REST 响应带 `x-ratelimit-limit` / `x-ratelimit-remaining`；登录 / magic link / 设备码与 REST 的两个公开端点按 IP 限流 |
| 数据清理 | Oban 定时任务，分批删除：`run_events` 保留 30 天（按运行整块删除，13 §1）、过期 7 天以上的运行令牌、过期的登录类令牌与设备码、GitHub 投递记录、Oban 任务 7 天、导出文件 24 小时与中断的导入（§1）。守护进程上的 CLI 会话不清理（恢复要用，`add-release-distribution` 决策 17） |
| 备份 | 以 `pg_dump` 为准；工作区 JSON 导出用于迁移和人工存档 |
| 安全 | Markdown 输出经 ammonia 净化（09 §4）；CSP：脚本与连接只放行本站（Mermaid 随前端打包，不走 CDN），`frame-ancestors 'none'`，表单只到本站与 GitHub（App manifest 流程）；所有令牌只存哈希；敏感配置用 cloak_ecto 加密；会话 Cookie `SameSite=Lax`，对外协议为 https 时 `Secure`；只信任配置的反向代理的转发头；GitHub webhook 校验签名。执行机器上的隔离见 14 §9 |

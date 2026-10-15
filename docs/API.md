# REST API

Helmsman 的 REST 接口给脚本、CI 和不支持 MCP 的工具用。大多数端点就是同名 MCP 工具的另一种传输：参数同名、取值规则与上限相同，成功时返回 `{"data": <该工具的 JSON 结果>}`，所以 MCP 文档里的说明同样适用。机器可读的完整描述在 `GET /api/v1/openapi.json`（OpenAPI 3，不需认证）。

## 认证与 scope

每个请求带工作区的 API Token（在「工作区设置 → API Token」创建）：

```
Authorization: Bearer hm_...
```

- `GET` 端点要求 Token 有 `api:read` 或 `api:write`（写包含读）；其余方法要求 `api:write`。缺少时 403 `insufficient_scope`。
- 工作区端点都在 `/api/v1/w/:slug/` 下，`:slug` 必须是 Token 所属的工作区，否则 404（不暴露别的工作区是否存在）。
- 每个请求都按 Token 用户在该工作区的**当前**角色执行；权限规则与网页、MCP 相同。
- 运行令牌（`hmr_`）、守护进程令牌（`hmd_`）与其他凭据一律 401。
- 唯一的例外是读取头像 `GET /avatars/:key`：`mcp`、`api:read`、`api:write` 任一 scope 都可以（MCP 视图里的 `avatar_url` 要能用同一个 Token 读取）；运行令牌与守护进程令牌仍然 401。

## 身份：`X-Helmsman-Actor`

写入记在谁名下、读取时「我」是谁（`/me/tasks` 等），按以下顺序确定：

1. 请求头 `X-Helmsman-Actor: keel/dev`，或写请求体里的 `actor` / `author`（与 MCP 写工具的同名参数相同）。两处都给且不同 → 400 `invalid_params`；
2. Token 的缺省 Agent；
3. Token 用户本人的 human 身份。

指定的名字必须是 Token 用户名下的 Agent，否则 403 `forbidden`；写入时停用的 Agent → 403 `agent_disabled`（读取允许停用的 Agent）。REST 不会创建会话 Agent。`GET /me` 显示当前身份及其来源。

例外：导出、导入及备份记录/下载总是以 Token 用户本人管理身份执行（admin 以上，replace 仅 owner），忽略缺省 Agent；`X-Helmsman-Actor` 只能省略或为本人 human 身份名。

`POST /autopilots/:id/run`（自动化是人管理的）总是以 Token 用户本人执行，忽略 Token 的缺省 Agent；`X-Helmsman-Actor` / `actor` 只能省略或写本人的 human 身份名，写 Agent 名 → 403 `forbidden`，不产生触发记录。

## 请求与响应

- 带请求体的请求必须是 `content-type: application/json` 的 JSON 对象：其他媒体类型 415 `unsupported_media_type`，解析失败 400 `invalid_json`，数组或标量 400 `invalid_params`，超过 8 MB 413 `payload_too_large`。
- `GET` 的查询参数按工具参数的类型转换：整数写十进制，布尔写 `true` / `false`，列表写成逗号分隔（`status=NEW,IN_PROGRESS`）或重复的 `status[]=NEW&status[]=DONE`。缺少必填参数或类型不对 → 400 `invalid_params`，`detail.fields` 列出出错的参数。未声明的参数忽略。
- 路径参数覆盖查询串与请求体里的同名参数。任务 ID 是 `KEY-N`；反馈是 `/tasks/:id/feedback/:seq`（`BOS-12#3` 即 `/tasks/BOS-12/feedback/3`）；运行 ID 是正整数，否则 404。
- `PATCH` 只改给出的字段，给 `null` 表示清空；可带 `lock_version`，与当前版本不同 → 409 `stale`，不带即后写覆盖。
- 新建返回 201，其余成功 200。列表没有统一的分页信封：分页参数与返回形态就是对应工具的（如 `list_tasks` 的 `limit` / `offset`）。

## 端点

工作区端点（路径相对 `/api/v1/w/:slug`）：

| 方法 | 路径 | 对应 | scope |
|---|---|---|---|
| POST | `/exports` | 排队导出（202），admin 以上 | write |
| GET | `/exports/:id` | 本人导出记录 | read |
| GET | `/exports/:id/download` | 本人未过期成功快照，application/gzip 附件 | read |
| POST | `/imports` | 原始 JSON/gzip 快照排队导入（202） | write |
| GET | `/imports/:id` | 本工作区导入审计，admin 以上 | read |
| GET | `/me` | 当前用户、角色、身份与 Token | read |
| GET | `/me/tasks` | `list_my_tasks` | read |
| GET | `/me/specs` | 待我处理的规格（待批准、请我评审） | read |
| GET | `/actors` | `list_actors` | read |
| GET | `/agents` | `list_agents`（含小队） | read |
| GET | `/avatars/:key` | 头像图片（`list_actors` 等返回的 `avatar_url`；带 `ETag`，`If-None-Match` 命中时 304） | read 或 mcp |
| GET | `/projects` | `list_projects` | read |
| POST | `/projects` | `create_project`（201） | write |
| GET | `/projects/:key` | `get_project` | read |
| PATCH | `/projects/:key` | `update_project` | write |
| GET | `/projects/:key/tasks` | `list_tasks` | read |
| POST | `/projects/:key/tasks` | `create_task`（201） | write |
| GET | `/tasks/:id` | `get_task` | read |
| PATCH | `/tasks/:id` | `update_task` | write |
| POST | `/tasks/:id/transition` | `transition_task` | write |
| GET | `/tasks/:id/feedback` | `list_feedback` | read |
| POST | `/tasks/:id/feedback` | `add_feedback`（201） | write |
| GET | `/tasks/:id/feedback/:seq` | 单条反馈 | read |
| PATCH | `/tasks/:id/feedback/:seq` | `update_feedback` | write |
| POST | `/tasks/:id/links` | `link_tasks`（`from` 为 `:id`） | write |
| DELETE | `/tasks/:id/links/:type/:to` | `unlink_tasks` | write |
| GET | `/tasks/:id/runs` | `list_runs` | read |
| GET | `/tasks/:id/spec` | `get_spec`（`version`、`files[]`） | read |
| PATCH | `/tasks/:id/spec` | `update_spec`（建立空规格时 201） | write |
| GET | `/tasks/:id/spec/diff` | `diff_spec`（`from`、`to`） | read |
| GET | `/tasks/:id/spec/events` | 规格的审计事件 | read |
| GET | `/tasks/:id/spec/export` | OpenSpec 目录压缩包附件（`version`、`format=tar.gz\|zip`、`reviews`） | read |
| POST | `/tasks/:id/spec/import` | 上传 OpenSpec 目录压缩包作为新版本（201；见下） | write |
| POST | `/tasks/:id/spec/versions` | `submit_spec_version`（201；`dry_run` 时 200） | write |
| GET | `/tasks/:id/spec/reviews` | `list_spec_reviews` | read |
| POST | `/tasks/:id/spec/reviews` | `submit_spec_review`（201） | write |
| POST | `/tasks/:id/spec/issues/:issue/notes` | `reply_spec_issue`（201） | write |
| POST | `/tasks/:id/spec/issues/:issue/ruling` | `rule_spec_issue`（201） | write |
| POST | `/tasks/:id/spec/review-requests` | `request_spec_review`（201） | write |
| DELETE | `/tasks/:id/spec/review-requests/:reviewer` | `cancel_spec_review`（名字里的 `/` 写成 `%2F`） | write |
| POST | `/tasks/:id/spec/finalize` | `finalize_spec`（人：定稿 / 批准；Agent：提议） | write |
| POST | `/tasks/:id/spec/reject` | 退回提议（只限人；体 `reason`、`wake`） | write |
| GET | `/search` | `search_tasks` | read |
| GET | `/query` | `query_tasks`（`bql`；`currentUser()` 是当前身份） | read |
| GET | `/filters` | `list_filters` | read |
| POST | `/filters` | `save_filter`（不带 `filter_id`，201） | write |
| GET | `/filters/:id` | 单个筛选器（带 `lock_version`） | read |
| PATCH | `/filters/:id` | `save_filter`（可带 `lock_version`，过期 409 `stale`） | write |
| DELETE | `/filters/:id` | `delete_filter` | write |
| GET | `/filters/:id/run` | `query_tasks`（`filter_id` 为 `:id`） | read |
| POST | `/runs` | `run_agent`（201；未派发 409 `not_dispatched`） | write |
| GET | `/runs/:id` | 运行摘要（member 以上带错误文本） | read |
| GET | `/runs/:id/events` | 执行记录（member 以上；`after_seq` / `before_seq` / `latest` / `limit`） | read |
| POST | `/runs/:id/cancel` | `cancel_run` | write |
| POST | `/runs/:id/retry` | 重试（返回新排队或已排队的重试） | write |
| POST | `/autopilots/:id/run` | 立即运行自动化（202，返回触发记录 `id`、`status`、`reason`；可带 `instructions`，≤ 4 KB） | write |

公开端点（不需认证，按客户端 IP 限流）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/workflow.md` | Agent 工作流 Markdown（`lang=en` 缺省，`lang=zh` 中文） |
| GET | `/api/v1/openapi.json` | OpenAPI 3 文档 |

BQL 的语法与字段见 `docs/BQL.md`。

## 错误

所有 `/api` 错误都是同一形态，`error` 是稳定的错误码，`message` 是给人看的英文说明（可能变化），`detail` 是细节（没有时为 `{}`）：

```json
{"error": "invalid_transition", "message": "...", "detail": {"from": "DONE", "to": "CANCELLED", "allowed": ["VERIFIED", "REJECTED"]}}
```

| 状态 | `error` | 说明 / `detail` |
|---|---|---|
| 400 | `invalid_params` | 参数不合法：`fields: {name: [msg]}` |
| 400 | `invalid_json` | 请求体不是合法 JSON |
| 401 | `unauthorized` | 缺少或无效的 Token（带 `WWW-Authenticate: Bearer`） |
| 403 | `insufficient_scope` | Token 缺 scope：`required` |
| 403 | `forbidden` | 角色或身份不允许 |
| 403 | `agent_disabled` | 写入身份已停用：`actor` |
| 404 | `not_found` | 不存在（含未知的 `/api` 路径）：`id` |
| 409 | `invalid_transition` | 不能从当前状态迁移：`from`、`to`、`allowed` |
| 409 | `blocked` | 依赖未完成：`blockers` |
| 409 | `replaced` | 已被取代：`replaced_by` |
| 409 | `self_verify_requires_tests` | 执行方自己验收须带通过的测试：`actor` |
| 409 | `cycle` | 依赖成环：`path` |
| 409 | `superseded` | 反馈已被修订：`latest` |
| 409 | `stale` | `lock_version` 过期 |
| 409 | `busy` | 并发修改过多，重试 |
| 409 | `project_archived` | 项目已归档 |
| 409 | `name_taken` | 名字已被占用 |
| 409 | `run_active` | 任务上仍有运行：`run_id`、`agent` |
| 409 | `already_finished` | 运行已结束，无需停止 |
| 409 | `already_retried` | 已被另一条运行重试：`run_id` |
| 409 | `not_ended` / `not_retryable` | 运行未失败或取消 / 不可重试（设计运行） |
| 409 | `agent_disabled` / `agent_archived` / `no_runtime` / `runtime_disabled` | 重试目标 Agent 或运行时不可用 |
| 409 | `task_closed` | 任务已验收或取消 |
| 409 | `run_rate_limited` | 该任务上启动运行过于频繁（不是 API 限流） |
| 409 | `not_dispatched` | Agent 未启动：`reason`（如 `unauthorized`、`no_runtime`） |
| 413 | `payload_too_large` | 请求体超过 8 MB |
| 415 | `unsupported_media_type` | 请求体不是 JSON |
| 422 | `validation_failed` | 字段校验失败：`fields` |
| 422 | `invalid_status` / `invalid_type` / `self_link` / `invalid_kind` | 状态名、关联类型、自关联、种类不合法 |
| 422 | `invalid_commits` / `invalid_tests` / `invalid_comment` / `invalid_feedback` / `invalid_instructions` / `invalid_query` | 对应参数不合法：`reason` |
| 422 | `not_managed` / `instructions_required` / `is_squad` | 只能启动托管 Agent / 没有任务时须给说明 / 目标是小队 |
| 422 | `invalid_bql` | BQL 不合法：`message`、`position` |
| 422 | `query_timeout` | 查询超时，缩小范围（如加 `project = KEY`） |
| 429 | `rate_limited` | 限流（带 `Retry-After`） |
| 500 | `internal` | 内部错误：`ref`（服务端日志用同一引用号记录细节） |

## 快照导入

`POST /imports?mode=merge&dry_run=false&source=helmsman` 的请求体为整个快照文件，接受 `application/json` 或 `application/gzip`，不经普通 8 MB JSON 解析器。上传与解压后分别受 `import_max_bytes` 限制（缺省 300 MB）。参数：`mode=merge|replace`、`dry_run=true|false`、`source=helmsman|bosun`、`rename[旧名]=新名`；replace 必须带 `confirm=<工作区 slug>`。

认证、scope、工作区、管理身份、参数、角色、进行中导入、存储与媒体检查均在读取请求体之前完成；拒绝请求不读文件、不落盘。超限或上传中断清理半成品；通过后返回 `data` 内的导入记录，后续通过 `GET /imports/:id` 查询完整报告。一次请求只扣一次 Token 限流额度。导出/导入 JSON 记录不含文件路径或内部 options；导出只给发起人，导入审计给本工作区管理员。

| 状态 | 备份错误码 | 说明 |
|---|---|---|
| 409 | `diverged` / `actor_kind_conflict` / `replace_blocked` / `cycle` / `busy` | 历史分叉、身份种类、活动运行/PR、依赖成环或已有导入 |
| 413 | `too_large` | 超过快照大小上限 |
| 422 | `invalid_import` / `confirmation_required` | 文件校验错误（`detail.errors`）或缺少 replace 确认 |
| 503 | `storage_unavailable` | 备份目录不可写 |

格式与 merge/replace 规则见 [EXPORT-FORMAT.md](EXPORT-FORMAT.md)。

## 规格

任务的规格（OpenSpec change：`proposal.md`、`design.md`、`tasks.md`、`specs/<capability>/spec.md`）。有对应 MCP 工具的端点与工具同参数、同规则、同结果。经 REST 写入的身份缺省是人（不带 `X-Helmsman-Actor` 且 Token 没有默认 Agent 时），所以：`POST /spec/finalize` 由人调用时直接定稿或批准提议（`wake` 缺省 true，唤醒执行方）；以 Agent 身份调用只会提议定稿（`pending_approval`）。`POST /spec/reject` 只限人，Agent 身份返回 403 `forbidden`。运行令牌（`hmr_`）不能调用任何 REST 端点（401）。

`GET /spec/export` 返回 `application/gzip` 或 `application/zip` 附件 `<change_id>-v<n>.tar.gz` / `.zip`：顶层目录为 `change_id`，内含 `.openspec.yaml`、该版本的文件，`reviews=true` 时还有 `reviews/spec-review-<n>.md`。解压到仓库的 `openspec/changes/` 下可直接 `openspec validate <change_id> --strict`。同一版本两次导出字节相同。

`POST /spec/import?base_version=<最新版本号>&note=...` 的请求体为 `application/gzip`（tar.gz）或 `application/zip`，不经 JSON 解析器：认证、scope、工作区、身份、参数与权限都在读取请求体之前检查。请求体超过 2 MB 返回 413，其他媒体类型返回 415；压缩包至多 200 个条目、解压后至多 1 MB，只能有普通文件与目录（链接、设备、绝对路径或含 `..` 的路径 → 422 `invalid_archive`）。去掉共同的目录前缀（如 `openspec/changes/<id>/`）后，允许的路径作为新版本的**全部**文件提交（压缩包里没有的文件在新版本里也没有）；`.openspec.yaml` 与 `reviews/` 下的文件忽略，其他路径在结果的 `warnings` 里列出。规格还没有版本时，前缀的最后一段若是合法且未被占用的 `change_id` 就用它。不加修改地导出再导入返回 409 `no_changes`。`dry_run=true` 只检查并返回与 `base_version` 的对比（200）。

| 状态 | `error` | 说明 / `detail` |
|---|---|---|
| 400 | `invalid_params` | 参数不合法：`fields` |
| 403 | `not_coordinator` | 只有协调者（小队 leader 以小队身份的运行、或任务的 Agent 执行方）或人可以做：`task`、`assignee`、`kind` |
| 404 | `spec_not_found` / `issue_not_found` / `request_not_found` / `version_not_found` | 任务没有规格 / 问题 / 待完成请求 / 版本不存在 |
| 409 | `stale_version` | 不是基于最新版本：`latest` |
| 409 | `spec_closed` / `not_closed` | 规格已定稿或已放弃（先重新打开）/ 只有定稿或放弃的规格能重新打开：`status` |
| 409 | `no_changes` / `no_version` / `no_proposal` / `pending_approval` | 与基础版本相同 / 还没有版本 / 没有待批准的提议 / 等待人批准 |
| 409 | `spec_invalid` | 版本未通过结构校验：`errors` |
| 409 | `unresolved_issues` / `reviews_pending` / `review_pending` | 有未解决的 P1/P2：`issues` / 有待完成的评审：`reviewers` / 该评审人已有待完成的请求 |
| 409 | `own_version` / `issue_resolved` | 不能评审自己写的版本 / 问题已有结论 |
| 422 | `invalid_files` / `invalid_issues` / `invalid_reviewer` / `invalid_archive` | 文件、问题、评审人、压缩包不合法：`errors` / `reviewer` / `reason` |

## 限流

- 工作区端点按 Token 限流，与该 Token 在 MCP 上的请求共用同一额度（缺省每分钟 600 次）。每个响应带 `x-ratelimit-limit`（额度）与 `x-ratelimit-remaining`（本窗口剩余）；超出返回 429 与 `Retry-After`（秒）。需要时给脚本单独建 Token。
- 两个公开端点按客户端 IP 限流（缺省每分钟 120 次）。

## 示例

```sh
export HM=https://helmsman.example.com/api/v1/w/acme
export TOKEN=hm_...

# 新建任务并派给自己的 Agent
curl -sS -X POST "$HM/projects/BOS/tasks" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title": "Fix login", "assignee": "keel/dev"}'

# 以自己的 Agent 迁移任务，并附一条反馈
curl -sS -X POST "$HM/tasks/BOS-13/transition" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "X-Helmsman-Actor: keel/dev" \
  -d '{"to": "DONE", "commits": ["0a1b2c3d"], "feedback": {"content": "Fixed in 0a1b2c3d."}}'

# 列出进行中的任务
curl -sS "$HM/projects/BOS/tasks?status=NEW,IN_PROGRESS&limit=20" \
  -H "Authorization: Bearer $TOKEN"

# BQL 查询：我负责的、进行中的任务
curl -sS -G "$HM/query" --data-urlencode 'bql=assignee = currentUser() AND status = in_progress' \
  -H "Authorization: Bearer $TOKEN"
```

# HelmsmanProtocol

服务端与守护进程共享的 v1 协议。只负责字符串键 JSON map 与经过校验的 Elixir 结构之间的转换，无网络、数据库或 JSON 库依赖。

## 连接与版本

连接 `wss://<server>/daemon/socket/websocket`，令牌通过 `x-helmsman-token` 请求头传递，不能放在 URL 中。
每个守护进程只加入 `daemon:<daemon_id>`，路径、请求头及 topic 由 `HelmsmanProtocol` 提供。
`join.protocol` 声明守护进程版本；当前版本与最低兼容版本均为 1。Phoenix 的 `vsn` 是序列化版本。

所有枚举严格校验：未知消息、事件、provider、状态、失败原因或错误码均被拒绝。
新增枚举值或消息、删除或改变字段的类型和语义必须升版本；新增可选字段可不升版本，接收方忽略未知字段。
服务端记录 join 的守护进程版本，只向它发送该版本支持的消息、字段与枚举值。
`Messages.encode(message, target_version)` 对不兼容目标返回 `{:error, {:not_in_version, target_version}}`；v1 只支持目标 1。
新守护进程连接旧服务端被 join 拒绝后停止重连。

## 使用

```elixir
{:ok, starting} = HelmsmanProtocol.Report.Starting.new(run_id: 7)
{:ok, {"starting", payload}} = HelmsmanProtocol.Messages.encode(starting, 1)
{:ok, ^starting} = HelmsmanProtocol.Messages.decode("starting", payload)
```

所有结构提供 `new/1`（atom 键 map 或 keyword，嵌套值可为 map 或对应结构）、`from_wire/1`、`to_wire/1`。
构造与解码均返回 `{:ok, struct}` 或 `{:error, {:invalid_payload, path, reason}}`；`path` 的字段名为字符串，列表下标为整数。
错误原因为 `:required`、`:type`、`{:enum, allowed}`、`{:too_long, max}`、`{:count, min, max}`、`:not_increasing`、`:not_allowed`。
可空字段编码为 null。ID 是正整数；序号确认值可为 0；时间编码为 ISO 8601 UTC，解码为 `DateTime`。
使用方负责 JSON 序列化，解码不根据外部字符串创建 atom。

`Messages.encode/2` 编码 Report / Push 消息；回复通过 `Messages.encode_reply(request_name, reply, target_version)` 编码，再通过 `Messages.decode_reply(request_name, payload)` 解码。
`sync` 与 `join` 共享回复，空回复使用 `Reply.Empty`，因此回复结构不对应唯一消息名。
Phoenix 的回复状态为 :error 时，用 `ErrorReply.from_wire/1` 解码；:ok 时用 `decode_reply/2`。
`ErrorReply.new(reason, message)` 与 `ErrorReply.unsupported_protocol(upgrade_url)` 返回同样的 ok/error 元组。
版本错误必须带 `server_version`、`min_version`、`upgrade_url`；普通错误只带 reason 与 message，解码忽略版本字段。

## 消息总表

Report 模块在 `HelmsmanProtocol.Report`，Reply 在 `HelmsmanProtocol.Reply`，Push 在 `HelmsmanProtocol.Push`。

| 名称 | 方向 | 负载模块与字段 | 成功回复模块与字段 |
|---|---|---|---|
| join | daemon → server | Join: protocol, machine, clis, max_concurrency, active_runs | Join: daemon_id, runtimes, terminate_run_ids |
| sync | daemon → server | Sync: machine, clis, max_concurrency | Join: 同 join |
| claim | daemon → server | Claim: 空 | Claim: runs（RunSpec 列表） |
| starting | daemon → server | Starting: run_id | Starting: action（proceed / abort）, reason（abort 必须有） |
| started | daemon → server | Started: run_id, session_id（可空） | Empty: 空 |
| events | daemon → server | Events: run_id, events（1–200 个 Event，批内 seq 严格递增） | Events: acked_seq |
| heartbeat | daemon → server | Heartbeat: runs（run_id, last_seq） | Heartbeat: terminate_run_ids |
| steer_ack | daemon → server | SteerAck: run_id, feedback_id | Empty: 空 |
| git_token | daemon → server | GitToken: run_id | GitToken: token, expires_at |
| pushed | daemon → server | Pushed: run_id, branch, base_sha, head_sha, commits（sha, subject）, rescue_branch（可空） | Empty: 空 |
| finished | daemon → server | Finished: run_id, status, failure_reason, error, session_id, summary, usage | Empty: 空 |
| rotate_token | daemon → server | RotateToken: 空 | RotateToken: token |
| runs_available | server → daemon | RunsAvailable: 空 | 无 |
| cancel | server → daemon | Cancel: run_id | 无 |
| steer | server → daemon | Steer: run_id, feedback_id, text | 无 |
| config_changed | server → daemon | ConfigChanged: 空 | 无 |
| revoked | server → daemon | Revoked: 空 | 无 |

machine = machine_id, name, os, arch, daemon_version。
clis 每项 = provider（claude / codex / copilot / cursor）, version, models, efforts, available, unavailable_reason。
available 与 unavailable_reason 互斥；version 可空，但 version 为空时 available 必须为 false。unavailable_reason 非空时 1–1024 字节。
active_runs 每项 = run_id, last_seq；runtimes 每项 = workspace_id, workspace_slug, provider, runtime_id。
Finished 中只有 failed 可且必须带 failure_reason；summary ≤ 4096 字节，error ≤ 16384 字节。
事件连续落库与重复终态接受由服务端处理；协议只校验单批序号。

## RunSpec

run_id；workspace（id, slug）；task（ident, title，整体可空）；
agent（name, provider, model, effort, custom_args, env, extra_mcp_servers）；prompt；resume_session_id（可空）；
repo（github_repository_id, clone_url, base_branch, branch, rescue_branches, git_token, git_token_expires_at，整体可空）；
mcp（url, token）；limits（timeout_ms, idle_timeout_ms）；trigger（kind, reason, feedback_id）。

custom_args 为最多 64 项的字符串列表，每项 1–4096 字节，不做 shell 拆分。
model、effort 为可空字符串，非空值 1–128 字节；env 为字符串 map；extra_mcp_servers 为 JSON 对象。
repo 非空时 github_repository_id 为必填正整数（GitHub 仓库 ID，改名和转移后不变）；git_token 和令牌过期时间必填；其他仓库标量为非空字符串。
trigger.kind 与可空 reason 为 1–64 字节自由字符串，feedback_id 可空；新增触发名称无需升版本。
Inspect 隐去 env 的值、extra_mcp_servers 与各令牌，保留环境变量名；to_wire 保留原始值。

## 事件类型

Event = seq（正整数）, type, data, at（UTC 时间）。大小按 UTF-8 字节计算；解码超限报错。
生成方先用 `Event.truncate(text, max_bytes)` 得到 `{text, truncated?}`，截断保证 UTF-8 字符完整。

| type | data | 字节上限 |
|---|---|---|
| text | text | 32768 |
| thinking | text | 32768 |
| tool_call | call_id（可空）, name, input | input 32768 |
| tool_result | call_id（可空）, output, is_error, truncated | output 16384 |
| usage | input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd | 计数为可空非负整数，费用为可空非负数，五个键必填 |
| session | session_id | — |
| result | text, success | — |
| error | reason, message | message 16384；reason 仅 daemon 可上报原因 |
| status | level（info / warning）, message | message 4096 |

Finished.usage 与 usage.data 共享 `Event.Usage`，整体可空。未报告的计数保留 null，与已报告的 0 区分。

## 失败原因

| 原因码 | 判定者 |
|---|---|
| timeout | daemon |
| stalled | daemon |
| provider_network | daemon |
| provider_rate_limit | daemon |
| provider_auth | daemon |
| provider_quota | daemon |
| cli_missing | daemon |
| cli_version | daemon |
| workspace_prepare | daemon |
| push_conflict | daemon |
| push_failed | daemon |
| context_overflow | daemon |
| cli_error | daemon |
| unknown | daemon |
| runtime_offline | server |
| daemon_restart | server |
| lease_expired | server |
| obsolete | server |
| unauthorized | server |

`FailureReason.all/0`、`daemon_reportable/0`、`server_only/0` 返回 atom 列表；编码后为表中字符串。
守护进程 finished 和 error 事件禁止上报 server 专用原因。
Channel 错误码：invalid_payload、unsupported_protocol、not_found、wrong_state。

## 设备码 HTTP

统一 JSON：`POST /daemon/device/code`（CodeRequest → CodeResponse）；`POST /daemon/device/token`（TokenRequest → TokenResponse）；
`POST /daemon/logout` 通过 x-helmsman-token 注销，服务端立即吊销令牌。
DeviceAuth 提供三个路径常量以及所有请求、回复结构。
CodeRequest: protocol, machine。CodeResponse: device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval。
TokenRequest: device_code。TokenResponse: token（hmd_ 前缀）, daemon_id, workspaces（id, slug, name）；Inspect 隐去 token。
user_code 为 XXXX-XXXX，字母表 `ABCDEFGHJKMNPQRSTUVWXYZ23456789`；device_code 仅用于接口，不显示给用户。
`decode_token_reply(status, payload)`：200 返回成功结构；400 的 authorization_pending / slow_down 返回 pending（slow_down 后增加 5 秒轮询间隔）；
expired_token / access_denied 返回 error；426 先验证结构化 ErrorReply 后返回 unsupported_protocol。

## 验证

`mise exec -- mix precommit` 与 `mise exec -- mix dialyzer`。
测试包含字段边界、嵌套错误路径、脱敏、消息目录，以及每个核心结构各 200 次固定种子的 JSON 往返。

# 12 · Agent 配置与运行时

> 参考 multica 的 agent / runtime 模型。Helmsman 里 Agent 有两种接入方式：
> **托管（managed）**——服务端派发，守护进程调起 CLI 执行（本文与 13–16）；
> **外接（external）**——bosun 式，人自己启动 Claude Code 等，通过 MCP + `identify` 接入（03、08）。两种可以混用。

## 1. 概念

| 概念 | 是什么 | 对应表 |
|---|---|---|
| **Agent** | 一个身份 + 一套执行配置（用哪个 CLI、什么模型、什么指令、在哪台机器跑）。不是常驻进程，被触发时才产生一次运行 | `actors`（kind = agent）+ `agent_profiles` |
| **守护进程**（daemon） | 装在某台机器上的 Helmsman 后台程序（14），属于一个用户 | `daemons` |
| **运行时**（runtime） | 「某台机器上的某个 Agent CLI」在某个工作区里的注册，如「alice 的 MacBook 上的 Claude Code」 | `runtimes` |
| **运行**（run） | Agent 的一次具体执行，见 13 | `runs` |

一台机器装了 Claude Code 和 Codex、用户属于两个工作区 → 一个守护进程，4 个运行时。重启守护进程会更新原有记录，不会重复创建。

## 2. Agent 配置（`agent_profiles`）

只有托管 Agent 有配置行；没有配置行的 agent actor 就是外接 Agent（`identify` 创建，03 §4），只是一个可署名的身份。

| 字段 | 说明 |
|---|---|
| `provider` | `claude` \| `codex` \| `copilot` \| `cursor`（14 §4） |
| `runtime_id` | 绑定的运行时。运行绑定这个运行时，离线时排队等待，**不会**换到别的机器上跑（会话恢复、本地环境都依赖同一台机器） |
| `provider_account_id` | 用哪个供应商账号（§2.2）。可空 = 用 CLI 自己的登录与配置；必须是所属用户自己的、CLI 相同的账号 |
| `model` / `effort` | 可空 = 用 CLI 的默认值；可选值由运行时上报（14 §2）；绑定了供应商账号时模型名不按运行时列表校验（由供应商决定） |
| `instructions` | Markdown：这个 Agent 是谁、怎么工作、交付要求。每次运行放在提示词最前面（13 §6） |
| `description` | 只用于展示，以及小队 leader 选择成员时参考（16） |
| `access` | 谁能触发它：`owner_only`（缺省）\| `workspace` \| `members`（+ `access_member_ids`） |
| `max_concurrency` | 这个 Agent 同时最多几个运行，缺省 2 |
| `timeout_minutes` / `idle_timeout_minutes` | 单次运行总时长上限（缺省 120，最大 1200：`hmr_` 最长 24 小时，要给准备与收尾留余量）/ 无输出多久判定卡死（缺省 20，最大 240） |
| `custom_args` | 追加给 CLI 的参数；协议相关的参数（输出格式、权限模式、`--resume` 等）会被剔除（14 §4） |
| `env` | 自定义环境变量。**加密存储**（`cloak_ecto`，密钥来自 `HELMSMAN_VAULT_KEY`），保存后界面上只显示变量名；不能覆盖 `HELMSMAN_*`。切换模型供应商不要用它（CLI 的用户配置会盖过它，§2.2），用 `provider_account_id` |
| `extra_mcp_servers` | 额外的 MCP 服务器（JSON），与 Helmsman 自己的 MCP 一起注入；同样加密 |
| `wake_on_requested` | 自己提出的任务有进展时是否被唤醒（13 §2.1 的「回调提出方」），缺省 true；随 `add-continuation-triggers` 加列 |
| `capabilities` | 运行时额外授予的能力，目前只有 `create_tasks`（13 §2.3）；缺省空，小队 leader 自动具备 |
| `archived_at` | 归档后不能再被触发，未结束的运行全部取消；历史保留 |

- Agent 的 actor 名就是它的名字（03 §1 的命名规则），在 @提及、指派、BQL 里都用这个名字。
- 托管 Agent 属于创建它的用户（`actors.owner_id`）。
- **执行相关的字段只有所属用户能改**：`provider` `runtime_id` `provider_account_id` `model` `effort` `instructions` `custom_args` `env` `extra_mcp_servers` `capabilities` `access`。这些字段决定在**主人的机器上**执行什么，admin 改了就等于能在别人机器上执行任意命令。admin 以上能查看（`env` 只看到变量名）、停用、归档，以及改 `description`、`max_concurrency`、超时。
- 改模型、改指令不会创建新 Agent，历史记录不受影响；只影响之后的运行。

### 2.1 谁能触发

触发者 = 造成这次运行的那个人；如果是托管 Agent 在运行中造成的（在反馈里 @了另一个 Agent、委派、在运行里建任务并指派——只限运行能力允许的这几种，13 §2.3；运行里不能调 `run_agent`），按该 Agent 所在运行的授权来源（`root_initiator_user_id`，13 §2.2）算，**不是** Agent 的所属用户；外接 Agent 用 `hm_` Token 操作时，触发者是 Token 的用户。「延续」类触发（打回、回答、回调提出方等）不看当时改状态的人，而是继承原来那次指派的授权，见 13 §2.1–2.2。

| `access` | 允许的触发者 |
|---|---|
| `owner_only` | 所属用户本人 |
| `members` | 所属用户 + 名单里的成员 |
| `workspace` | 工作区里所有 member 以上的成员 |

**小队**：能触发小队 = 能触发它的 leader，并且能触发小队里每一个托管 Agent 成员（人类成员不影响），见 16 §1.1。

工作区 owner / admin 能看到、能修改所有 Agent，但**不能绕过 `access` 去触发**别人的 `owner_only` Agent——运行用的是别人的机器和 CLI 账号额度。无权触发时：指派照常保存，但不产生运行，界面和 MCP 都会说明原因。

### 2.2 供应商账号（`provider_accounts`）

同一台机器、同一个 CLI，用户可能有多个模型供应商的账号（如 Claude Code 接 z.ai 与火山方舟），希望不同 Agent 各用各的地址、密钥与模型，分别计费（`add-provider-accounts`）。

- **属于用户，不属于工作区**：名称、CLI 类型（`claude` | `codex`，创建后不可改）、base URL（`https`；本机回环地址可 `http`；不含凭据与查询串）、密钥、模型映射（Claude：`default` `opus` `sonnet` `haiku` `fable` `subagent`；Codex：`default`，必填）。在个人设置页增删改，每人最多 32 个。
- **密钥只写不读**：加密存储，读取只给「已设置」；编辑时留空 = 不变，不能清空；错误与日志里不出现。
- **只有所属用户能用**：Agent 只能绑定所属用户自己的、CLI 相同的账号；多个 Agent 共用一个账号，换密钥只改一处，之后领取的运行生效。仍被未归档 Agent 绑定的账号不能删除。别人（含 owner / admin、实例管理员）看不到、用不了；工作区成员读取 Agent 时只看到账号名与主机名。账号的增删改查只能在本人的网页会话里做（管理动作 `manage_provider_accounts`）：运行令牌、Agent 身份、`hm_` Token 一律不能读写，即使属于同一个用户；密钥只在领取运行时读出、写进 RunSpec。
- **为什么不用 `env`**：CLI 的用户配置会盖过进程环境（Claude Code 的 `~/.claude/settings.json` 的 `env`；Codex 配置里选定的 `model_provider`），而且只覆盖地址和令牌不够——用户配置里的 `apiKeyHelper`、模型映射会一起漏到 Agent 的供应商那里。守护进程按账号生成覆盖（Claude 用 `--settings`、Codex 用 `-c model_providers.helmsman_account`，14 §4），密钥只经进程环境 `HELMSMAN_PROVIDER_API_KEY` 交给 CLI，不落盘、不进命令行（没有写进私有文件的退路）；做不到就中止运行。
- **运行**：领取时把账号放进 RunSpec，运行记下所用账号（可追溯计费到哪个账号）。协议版本低于引入账号的版本的守护进程不领取绑定了账号的运行（排队，可派发性显示 `daemon_outdated`）。
- 未绑定账号的 Agent 行为不变：用机器上 CLI 自己的登录与配置。

## 3. 守护进程与运行时

### 3.1 注册

1. 用户在机器上执行 `helmsman login --server https://helmsman.example.com`：设备码流程（类似 `gh auth login`）——终端显示一个短码，用户在浏览器 `/device` 页面登录、**勾选这台机器要服务的工作区**并确认，守护进程拿到 `hmd_` 令牌（§4）。之后可以在设置页增减工作区。HTTP 接口与错误码见 `protocol/`（`add-daemon-protocol` 的 `DeviceAuth`）。
2. `helmsman daemon start`：连接服务器（14 §3），上报机器信息和检测到的 CLI（名称、版本、可用模型）。
3. 服务端为「这台机器 × 每个检测到的 CLI × 勾选的每个工作区」upsert 一条 `runtimes`。用户可以在设置页关掉某个 CLI。

### 3.2 字段

| 表 | 列 |
|---|---|
| `daemons` | `user_id`、`machine_id`（守护进程首次启动时生成并持久化）、`name`（缺省主机名，可改；重新登录不改名）、`os`、`arch`、`version`、`protocol_version`、`token_hash`、`token_issued_at`、`previous_token_hash` / `previous_token_expires_at`（轮换后旧令牌的 24 小时宽限）、`auth_epoch`（授权代次，缺省 1：同机重新登录与吊销时加 1，轮换不变；旧代次的连接与令牌不能再写入，`add-agent-profiles-runtimes` 决策 21）、`max_concurrency`（守护进程上报，缺省 4）、`last_seen_at`、`revoked_at` |
| `runtimes` | `workspace_id`、`daemon_id`、`provider`、`cli_version`、`models text[]`、`efforts text[]`、`status`（`online` \| `offline`）、`unavailable_reason`（CLI 找到了但不可用的原因）、`disabled_at` |
| `local_repositories` | 与运行时一样由守护进程上报、按工作区登记：机器主人在 `config.toml` 里登记的本地仓库（名字、显示用的路径、开放给哪些工作区）。路径只在机器上配置，服务端不下发路径（15 §8） |

唯一键 `(workspace_id, daemon_id, provider)`。

### 3.3 运行时只属于主人

- 运行时**只能绑定主人自己的 Agent**：Agent 的所属用户（`actors.owner_id`）必须等于运行时所在守护进程的 `user_id`。owner / admin 也不例外——那是别人的机器和 CLI 额度。绑定在保存 Agent 配置的事务里校验（01 §3）。
- 本期没有「公开运行时」。原因：守护进程只实现 `isolation = none`（14 §9），CLI 和守护进程是同一个系统用户；如果允许别人的 Agent 路由到这台机器，它就能以机器主人的身份执行任意命令、读到 `hmd_` 令牌和其他任务的 worktree。真正的多用户隔离（每个用户一个执行用户或容器）是扩展点（00 §10）。
- **多人共用一台服务器**：建一个专用的 Helmsman 账号（例如 `build-box`，在工作区里是 member），用它在服务器上 `helmsman login`；再以这个账号创建 Agent，`access = workspace`（§2.1）。成员都能触发这些 Agent，执行时用的是这台服务器上专用系统用户的环境与 CLI 额度；Agent 的执行配置只有登录这个账号的人能改（§2）。风险落在这台服务器和这个专用账号上，而不是某个成员的个人机器上。

### 3.4 在线状态

- 在线 = 最近 2 分钟内收到过守护进程的 `join`、`sync` 或心跳（每 30 秒一次）；超过 2 分钟没有上报、或已被吊销，由每分钟一次的定时任务把它的运行时标记离线并广播。断线重连、重启都落在这 2 分钟宽限期里；心跳停了但连接没断（守护进程卡死）同样判离线。不用 Presence：判定不依赖连接进程在哪个节点（`add-agent-profiles-runtimes` 决策 12）。
- 离线时：排队中的运行继续等；进行中的运行在宽限期后判定失败（`runtime_offline`），按 13 §5 重试。
- 吊销守护进程（设置页或 `helmsman logout`）：令牌失效、连接被踢掉、它的运行时全部离线。

## 4. 令牌

在 03 §2 的 API Token（`hm_`）之外新增两种，都只存 SHA-256：

| 前缀 | 发给谁 | 绑定 | 能做什么 | 有效期 |
|---|---|---|---|---|
| `hmd_` | 守护进程 | 用户 + 机器 + 勾选的工作区 | 只能连守护进程 Channel（14 §3）：领取运行、上报事件。**不能**调 MCP / REST | 长期，可吊销；守护进程每 30 天自动轮换 |
| `hmr_` | 一次运行里的 Agent CLI | 工作区 + Agent + 运行 | 只能调 `/mcp`；身份固定为这个 Agent，`identify` 和 `actor` 参数无效（08 §1）；能做什么由运行的 `capabilities` 决定（13 §2.3），缺省只能写本次运行的任务 | 运行进入终态即失效（运行只会被领取一次，令牌不会「复活」）；最长 24 小时 |

`hmr_` 以环境变量 `HELMSMAN_RUN_TOKEN` 交给 CLI，不写进提示词、日志或仓库文件（14 §5）。能力之外，权限上限仍是所属用户在该工作区的角色，管理类动作一律不允许。

## 5. 界面

- `/w/:slug/agents`：Agent 列表（在线 / 忙碌 / 空闲 / 离线、所属用户、CLI、最近运行）；新建、编辑、归档。
- `/w/:slug/agents/:name`：配置、正在跑和排队的运行、历史运行、用量统计。
- `/w/:slug/settings/runtimes`：我的机器与运行时（在线状态、CLI 版本、并发上限）；admin 看全部，可以禁用。
- 新建 Agent 的表单里，运行时下拉只列出自己的运行时（§3.3），模型下拉来自所选运行时上报的列表；「供应商账号」下拉只列出自己的、与所选 CLI 相同的账号（空 = CLI 默认登录），选了账号后模型改为自由输入。
- 个人设置页：供应商账号的增删改（§2.2），列出每个账号被哪些 Agent 使用。

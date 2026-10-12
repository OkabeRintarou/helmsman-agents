# 14 · 守护进程（helmsman daemon）

> 装在执行机器上的 Elixir 程序：连上服务器、领取运行、调起本机的 Agent CLI、把过程和结果传回去。
> 和服务端在同一个仓库（`daemon/`），共享协议定义（`protocol/`），见 00 §5。

## 1. 分发与命令

- 打包：Burrito 打成单文件，目标 linux-x64、linux-arm64、macos-arm64、macos-x64；首期不支持 Windows。
  依赖里有原生代码（erlexec 的端口程序），所以每个目标在**对应平台的 CI runner 上原生构建**，不走交叉编译。
- 安装：`curl -fsSL https://<server>/install.sh | sh`（从服务端下载与服务端版本匹配的二进制），或 GitHub Releases。
- 服务端在 `join` 时检查守护进程的协议版本（§3）；不兼容时拒绝并提示升级，守护进程停止重连。

| 命令 | 作用 |
|---|---|
| `helmsman login --server URL` | 设备码登录，得到 `hmd_` 令牌（12 §3.1） |
| `helmsman daemon start [--foreground]` | 启动；缺省后台运行（Linux 写 systemd user unit，macOS 写 launchd plist）。后台服务管理随 `add-release-distribution` 交付，此前只有前台运行 |
| `helmsman daemon stop \| restart \| status \| logs -f` | 管理后台服务（随 `add-release-distribution`） |
| `helmsman runtimes` | 列出检测到的 CLI、版本、绑定的工作区 |
| `helmsman logout` | 吊销本机令牌 |

本地文件：

```
~/.helmsman/
├── config.toml           # 服务器地址、并发上限、工作根目录、[[local_repositories]]（本地仓库模式，15 §8）
├── credentials           # 服务器地址、daemon_id、hmd_ 令牌、签发时间（0600）；macOS 钥匙串随 add-release-distribution
├── machine_id            # 首次运行时生成的随机 ID
├── state/                # 当前运行的本地记录（崩溃恢复用）
├── repos/<host>/<owner>/<repo>.git     # 仓库的 bare 镜像缓存
├── repos/local/<name>.git              # 本地仓库模式：从机器上用户仓库 fetch 的缓存（15 §8）
├── work/<workspace_id>/<ident>/        # 任务的 git worktree，同一任务的后续运行复用（用不变的工作区 ID）
├── scratch/<workspace>/<ident>/        # 没有仓库的任务的工作目录，同样复用（CLI 按工作目录保存会话）
├── codex/                              # 守护进程专用的 CODEX_HOME（持久：Codex 的会话存在这里，恢复要用）；provider 与登录由机器主人配置，守护进程不写入
└── runs/<run_id>/                      # 单次运行的私有目录：MCP 配置、临时文件、原始日志
```

## 2. 启动与 CLI 检测

- 在 `PATH` 里找 `claude`、`codex`、`copilot`、`cursor-agent`，执行 `--version` 取版本；低于最低支持版本的标记为不可用并说明原因。
- 能列出模型的 CLI 顺便取模型列表（例如 `cursor-agent --list-models`），连同支持的推理强度（如 Claude 的 `--effort`），随注册上报，供界面下拉。
- 每 10 分钟重新检测一次；`helmsman daemon restart` 立即重测。
- 一个 CLI 都没有时拒绝启动，并提示去安装。

## 3. 与服务端的协议

用 Phoenix Channel（WebSocket），客户端库是 Slipstream。只有一条连接，所有消息都走它，没有额外的 HTTP 轮询——断线时 Slipstream 指数退避重连，重连后做一次对账（下文 `join`）。

- Socket：`wss://<server>/daemon/socket/websocket`；`hmd_` 令牌放在请求头 `x-helmsman-token`（服务端用 `connect_info: [:x_headers]` 读取），**不放进 URL**——查询串会进代理和访问日志。`vsn` 参数是 Phoenix 自己的序列化版本，协议版本不用它。
- Topic：`daemon:<daemon_id>`（登录时与令牌一起拿到 `daemon_id`）；`join` 的负载带协议版本 `protocol`，服务端只接受 `HelmsmanProtocol` 声明的兼容范围，否则回复 `unsupported_protocol`（附服务端版本与升级地址）。消息结构、校验与编解码都在 `protocol/`（`add-daemon-protocol`）。

**守护进程 → 服务端**（都用带回复的 push，失败重发）。关于某条运行的消息，服务端只接受**领取它的那个守护进程**、且运行处于预期状态时的上报（13 §1「一条运行只会被领取一次」）；事件按 `(run_id, seq)` 去重：

| 消息 | 内容 / 回复 |
|---|---|
| `join` | 协议版本、机器信息、检测到的 CLI、本机认为仍在跑的运行。回复：`daemon_id`、每个工作区每个 CLI 的 `runtime_id`；需要立即终止的运行 |
| `sync` | 与 `join` 相同的机器信息与 CLI 列表：每 10 分钟重新检测后（§2）、收到 `config_changed` 后发送。回复同 `join` |
| `claim` | 无参数（空闲槽位由服务端算，13 §4.1）→ 运行描述列表（下表） |
| `starting` | `run_id`：工作目录已就绪，请求启动 CLI。回复 `proceed` 或 `abort`（13 §4.2） |
| `started` | `run_id, session_id?` |
| `events` | `run_id, [%{seq, type, data, at}]`，最多每秒一批、每批 ≤ 200 条。回复：已连续落库的最大 `seq`，守护进程据此丢弃缓冲 |
| `heartbeat` | 每 30 秒；所有在跑的运行的 `run_id, last_seq`。回复：服务端认为已结束、应立即终止的运行 |
| `steer_ack` | `run_id, feedback_id`：CLI 已把插话纳入当前会话（以适配器的确认为准）；与事件同一套重发，`finished` 在它得到回复之后才上报（13 §8） |
| `git_token` | `run_id`：请求新的推送令牌（安装令牌 1 小时过期，长任务结束时可能已失效） |
| `cleanup_check` | 协议 Vc（`add-pr-reconcile-merge`）：1–500 个 `{workspace_id, ident}`。回复每项 `deletable`、`base_branch`、`pushed_heads`（§7 第 4 步） |
| `repo_status` | 协议 3：本地仓库模式下，`join` / `sync` 回复给出要检查的分支，守护进程 fetch 用户仓库后上报每个分支的提交是否已进入基础分支（15 §8） |
| `pushed` | `run_id, branch, base_sha, head_sha, commits, rescue_branch?` |
| `finished` | `run_id, status, failure_reason?, error?, session_id, summary, usage` |
| `rotate_token` | 令牌满 30 天时请求新的 `hmd_`（12 §4）。回复新令牌；旧令牌在 24 小时宽限期后失效 |

**服务端 → 守护进程**：

| 消息 | 作用 |
|---|---|
| `runs_available` | 有新运行可领（只是提示，守护进程随后发 `claim`） |
| `cancel` | `run_id`：中断这次运行 |
| `steer` | `run_id, feedback_id, text`：插话（13 §8） |
| `config_changed` | 运行时开关等变了，守护进程发一次 `sync`（Agent 配置不需要拉取：每次领取时都在运行描述里） |
| `revoked` | 令牌被吊销，守护进程停止并删除本地令牌 |

**运行描述**（`claim` 的回复，结构定义在 `protocol/`）：

```elixir
%RunSpec{
  run_id, workspace: %{id, slug}, task: %{ident, title} | nil,
  agent: %{name, provider, model, effort, custom_args, env, extra_mcp_servers,
           provider_account: %{base_url, api_key, models} | nil},   # 12 §2.2；协议 2 起（`add-provider-accounts`）
  prompt,                          # 服务端生成（13 §6）
  resume_session_id,               # 同一运行时上的上一次会话；可空
  repo: %{clone_url, github_repository_id, base_branch, branch, rescue_branches, git_token, git_token_expires_at} | nil,   # 15 §2；缓存按 github_repository_id 定位
  mcp: %{url, token},              # https://<server>/mcp + hmr_ 令牌
  limits: %{timeout_ms, idle_timeout_ms}
}
```

## 4. CLI 适配器

每种 CLI 一个模块，实现同一个行为：

```elixir
@callback provider() :: :claude | :codex | :copilot | :cursor
@callback executable() :: String.t()
@callback min_version() :: Version.t()
@callback detect() :: {:ok, %{version: String.t(), models: [String.t()], efforts: [String.t()]}} | {:error, String.t()}   # efforts 可省略，缺省 []
@callback prepare(spec, run_dir, work_dir) :: {:ok, %Launch{argv, env, stdin, close_stdin?, events}} | {:error, {reason, message}}
@callback init_state(spec) :: state
@callback handle_output(:stdout | :stderr, line :: binary, state) :: {[event], [:close_stdin | {:write, iodata}], state}
@callback finish(exit_status, state) :: {:succeeded | {:failed, reason, message}, %{session_id, summary, usage}}
@callback steer(ref, text, state) :: {:ok, iodata, :delivered | :pending, state} | :unsupported   # :pending 时之后由 handle_output 的动作 {:steer_result, ref, :delivered | {:rejected, msg}} 确认（add-run-steering 决策 11）
@callback interrupt(state) :: {:write, iodata} | :signal
```

| | 启动命令（无人值守） | 提示词怎么给 | 注入 Helmsman MCP | 恢复会话 | 插话 |
|---|---|---|---|---|---|
| **Claude Code** | `claude -p --input-format stream-json --output-format stream-json --verbose --permission-mode bypassPermissions --strict-mcp-config --mcp-config <run_dir>/mcp.json [--model] [--effort] [--resume <id>]` | stdin 写一帧 stream-json 用户消息，stdin 保持打开；收到 `result` 后关闭 stdin | `--mcp-config` 指向私有目录里的 JSON（HTTP 服务器 + `Authorization: Bearer ${HELMSMAN_RUN_TOKEN}`，CLI 展开环境变量，令牌不落盘；2.1.246 实测，`add-claude-adapter` 决策 16） | `--resume` | stdin 再写一帧用户消息；送达信号与关闭 stdin 的时机以实测为准，找不到可靠信号则不支持（`add-run-steering` 决策 12） |
| **Codex** | `codex app-server --disable shell_snapshot --disable shell_snapshot_v2`（stdio 上的 JSON-RPC：`initialize` → `thread/start` 或 `thread/resume` → `turn/start`；审批 `never`、沙箱 `danger-full-access`），环境变量 `CODEX_HOME=~/.helmsman/codex` | `turn/start` 的参数 | `thread/start` 的 `config` 写 `mcp_servers.helmsman = {url, bearer_token_env_var = "HELMSMAN_RUN_TOKEN"}`（streamable HTTP，令牌不落盘、不进命令行）。用守护进程专用、持久的 `CODEX_HOME` 隔离：守护进程**不读不改不复制**用户的 `~/.codex`，provider 与登录由机器主人在其中配置一次；该目录的 `config.toml` 定义了 MCP 服务器时 CLI 不可用；工作目录或仓库根有 `.codex/config.toml` 时拒绝运行（`workspace_prepare`，未信任的项目配置也会生效）。不支持 MCP prompts（提示词只依赖工具与资源） | `thread/resume` | 当前 turn 内追加输入（`turn/steer`），成功回复即送达（`add-run-steering` 决策 11） |
| **Copilot CLI** | `copilot -p <prompt> --output-format json --allow-all --no-ask-user --disable-builtin-mcps --additional-mcp-config @<run_dir>/mcp.json [--model] [--resume <id>]`，环境变量 `COPILOT_HOME=<run_dir>/copilot-home` | 命令行参数（所以提示词要短，13 §6） | `--additional-mcp-config @文件`（注意 `@` 前缀，否则会被当作 JSON 字符串）。它会**追加**而不是替换用户的 `mcp-config.json`，所以用私有的 `COPILOT_HOME` 隔离，只放入登录所需的文件 | `--resume` | 不支持 → 结束后续跑 |
| **Cursor CLI** | `cursor-agent -p --output-format stream-json --force --workspace <work_dir> [--model] [--resume <id>]`，环境变量 `CURSOR_DATA_DIR=<run_dir>/cursor-data` | stdin（写完关闭） | Cursor 只从项目目录读 MCP 配置：写 `<work_dir>/.cursor/mcp.json`，并在私有的 `CURSOR_DATA_DIR` 里只批准这一个服务器（不用 `--approve-mcps`，否则仓库和用户已有的 MCP 也会被批准）。仓库里已有 `.cursor/mcp.json` 时**拒绝运行**（`workspace_prepare`），不覆盖；文件加进 `$(git rev-parse --git-path info/exclude)` | `--resume` | 不支持 → 结束后续跑 |

- 上表参数按本机现有版本核对过帮助信息（claude、codex-cli 0.161、Copilot CLI 1.0.95、cursor-agent 2026.04）。各 CLI 演进很快：每个适配器开工时先做一次实测，确认输出事件格式、MCP 注入、会话恢复、私有配置目录下的登录真的可用，再定稿适配器（Claude、Codex 的实测与决策见 `add-claude-adapter`、`add-codex-adapter`）。
  已知风险：`codex app-server` 在 0.162 里仍标为实验性，选它是因为结构化错误码、`turn/interrupt`、`turn/steer`（`add-codex-adapter` 决策 1），备选是 `codex exec --json`（不支持插话）；私有配置目录若同时保存会话（Codex 即如此），就必须持久而不是随运行删除，否则无法恢复会话——Copilot / Cursor 实测时同样确认；Copilot / Cursor 换了配置目录后能否沿用用户的登录，需要实测确定要复制哪些文件；Cursor 的 `mcp.json` 是否支持用环境变量引用令牌也要实测，不支持时令牌只能写进这个被排除的文件（0600），运行结束即删除。做不到隔离的 CLI，适配器就不启用（fail closed），而不是退回到加载用户全部 MCP。
- `custom_args` 追加在固定参数之后；协议相关的参数（`-p`、`--output-format`、`--input-format`、`--permission-mode`、`--resume`、`--mcp-config` 等）被剔除，并在运行事件里记一条警告。
- Claude Code 拒绝在 root 下用 `bypassPermissions`：守护进程以 root 运行时启动直接失败，提示换用普通用户（与 §9 的安全建议一致）。
- **供应商账号**（12 §2.2，`add-provider-accounts`）：RunSpec 带 `agent.provider_account` 时才生效，否则启动方式与上表逐字节相同。
  - Claude Code：用户 `settings.json` 的 `env` 高于进程环境，仓库的 `.claude/settings*.json` 更高，命令行 `--settings` 最高（托管策略除外）。所以加 `--settings <run_dir>/claude-settings.json`（0600，不含密钥、不含 `null`——含 `null` 的设置文件会被整个静默忽略）：把决定地址、凭据、模型的全部变量先置空串再写入账号的地址与模型映射，顶层 `model` 同样覆盖，`apiKeyHelper` 改为 `printenv HELMSMAN_PROVIDER_API_KEY`（设置文件的 `env` 不展开变量，helper 让密钥只留在进程环境里）。不换 `CLAUDE_CONFIG_DIR`：那样用户的登录、hooks、会话都不加载，仓库设置仍能改地址。守卫：初始化行的 `apiKeySource` 不是 `apiKeyHelper` 就中止运行。
  - Codex：守护进程不读用户的 `~/.codex`；专用目录 `config.toml` 的 `model_provider` 高于 `OPENAI_*` 环境变量，`-c` 高于 `config.toml`，`-c` 对已有 id 逐键合并。所以用保留 id：`-c model_provider="helmsman_account" -c model_providers.helmsman_account={base_url=…, wire_api="responses", env_key="HELMSMAN_PROVIDER_API_KEY"}`；专用 `config.toml` 定义了这个 id 时 CLI 不可用；`thread/start` 回复的 `modelProvider` 不是它就中止。
  - 绑定账号时 `custom_args` 里改供应商的参数（Claude 的 `--settings` / `--setting-sources`，Codex 的 `-c model_provider*`）被剔除；未绑定账号而 Agent `env` 里有供应商变量时，运行事件里警告（只列变量名）。

**输出归一化**：各适配器把 CLI 的输出解析成同一组事件——`text`（助手文本，增量合并）、`thinking`、`tool_call`（名称、参数摘要）、`tool_result`（截断到 16 KB）、`usage`、`session`（会话 ID）、`result`（最终输出、是否成功）、`error`（附原因码，13 §5）。原始输出另存在 `runs/<run_id>/raw.log`，7 天后清理，排查时用。

## 5. 运行环境

- 工作目录：有仓库时是任务的 worktree（§7）；没有仓库时，有任务的用 `scratch/<workspace>/<ident>/`（同一任务复用，会话才能恢复），无任务的（自动化「仅运行」）用 `runs/<run_id>/scratch/`。
- 环境变量：继承守护进程的环境 + Agent 的 `env`，再加上：

| 变量 | 值 |
|---|---|
| `HELMSMAN_RUN_TOKEN` | `hmr_` 令牌（只给 MCP 用） |
| `HELMSMAN_PROVIDER_API_KEY` | Agent 绑定了供应商账号时的密钥（12 §2.2），只给 CLI 的认证用（Claude 的 `apiKeyHelper`、Codex 的 `env_key`） |
| `HELMSMAN_SERVER_URL` / `HELMSMAN_RUN_ID` / `HELMSMAN_TASK` | 供 Agent 或脚本参考 |
| `TMPDIR` | `runs/<run_id>/tmp` |
| `CODEX_HOME` / `COPILOT_HOME` / `CURSOR_DATA_DIR` | 各 CLI 私有的配置目录：`CODEX_HOME` 是守护进程专用的持久目录 `~/.helmsman/codex/`（会话恢复要用）；其余在 `runs/<run_id>/` 下（实测确认是否也要持久） |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`（及 `GIT_COMMITTER_*`） | 有仓库时：Agent 名与 `<agent>@agents.<服务器域名>`（Agent 名中的 `/` 等字符换成 `-`），提交记录能看出是哪个 Agent 写的 |

- **推送用的 GitHub 令牌不给 Agent**：它只在守护进程自己执行 `git fetch/push` 时通过 `GIT_ASKPASS` 临时提供，不进 CLI 的环境。
  但这**不等于** Agent 推不了代码：机器用户自己配置的 SSH 密钥、`gh` 登录，Agent 照样能用。要让「推送和合并只能经过 Helmsman」真正成立，按 §9 用一个**没有配置任何 GitHub 凭据**的专用系统用户运行守护进程。
- 关掉 CLI 自带的、可能带写权限的集成：Copilot CLI 加 `--disable-builtin-mcps`（否则内置的 GitHub MCP 会用用户的 GitHub 身份）并用私有 `COPILOT_HOME`；Claude 用 `--strict-mcp-config` 只加载我们给的 MCP；Codex 用守护进程专用的 `CODEX_HOME`（不加载用户的 `~/.codex`），Helmsman 的 MCP 由 `thread/start` 注入，专用目录或项目里另有 MCP 配置时不运行，并一律以 `--disable shell_snapshot --disable shell_snapshot_v2` 启动（否则 CLI 把整个进程环境——运行令牌、供应商密钥、Agent 的 `env`——写进共用的 `CODEX_HOME/shell_snapshots/`；启动前删除该目录里已有的快照，`add-provider-accounts` 决策 19）；Cursor 用私有 `CURSOR_DATA_DIR` 只批准我们的服务器。
- MCP 配置文件只放在私有目录 `runs/<run_id>/`（0600），不写进仓库；Cursor 的例外见上表。
- 运行结束后删除 `runs/<run_id>/`（原始日志除外），worktree 保留给同一任务的下一次运行。

## 6. 进程管理

- 用 erlexec 启动 CLI：独立进程组（`{:group, 0}` + `:kill_group`），stdin / stdout / stderr 都接到 `RunWorker` 进程。BEAM 崩溃时 erlexec 会连带杀掉子进程，不留孤儿。
- **停止**：先走适配器的 `interrupt/1`（Codex 发 `turn/interrupt`；其他发 SIGTERM 给整个进程组），10 秒内没退出则 SIGKILL 整个进程组（CLI 拉起的 MCP 服务器、shell、测试进程一起结束）。
- **超时**：总时长超过 `timeout_ms` → 停止，`failed(timeout)`；超过 `idle_timeout_ms` 没有任何输出事件 → `failed(stalled)`。
- **并发**：守护进程的 `max_concurrency`（缺省 4）上报给服务端，服务端据此算空闲槽位；单个 Agent 的并发也由服务端控制（13 §4.1）。

## 7. 代码与分支

细节和 PR、合并流程见 15；守护进程负责的部分：

1. **准备**（在发 `starting` 之前完成）：
   - `repos/` 下每个仓库一个 bare 仓库，路径按 GitHub 仓库 ID 定位（`repos/<host>/<仓库 ID>.git`：仓库改名、转移后仍是同一个缓存，只更新 `origin` 地址；项目改绑到别的仓库时旧 worktree 属于另一个缓存，准备失败并要求人工处理，`add-daemon-git-workspace` 决策 18）（`git init --bare` 后添加 `origin`；不用 `clone --bare`，它把远端分支映射到 `refs/heads/*`），fetch refspec 设为 `+refs/heads/*:refs/remotes/origin/*`——远端分支只进 `refs/remotes/origin/*`，本地的 `refs/heads/*` 只留给任务 worktree，fetch 不会和已检出的分支冲突（`--mirror` 会，所以不用）。改共享目录的操作（fetch、建 worktree）用每仓库一把本地锁串行；每个任务的 worktree 另有一把锁，从准备持有到收尾结束。锁用内核的 `:global` 锁，归持有它的 `RunWorker` 所有，只随它释放或退出而释放（不设自己记账的锁服务：它重启会丢锁）；守护进程的 git 命令在独立进程组运行，持有者退出时一并被杀；执行 git 的进程以同一请求者共同持有锁，确认旧进程组清空后才放行下一个持有者（`add-daemon-git-workspace` 决策 19）。准备整体限时 8 分钟（领取租约 10 分钟）。
   - 任务分支 `hm/<workspace_id>/<ident 小写>`（同一仓库可能先后属于两个工作区，`add-daemon-git-workspace` 决策 2）在远端已存在 → 从远端的它建（或快进已有的；本地有未推送的提交则保留，分叉则合并远端）worktree；不存在 → 从 `origin/<base_branch>`（项目设置的基础分支，RunSpec 里给出）建。准备时远端已有的提交（远端任务分支，没有则基础分支）记为推送基准，收尾的 `base_sha` 与提交列表相对它计算。worktree 里有上次运行留下的未提交改动或未推送提交时保留它们、不从远端更新，并由本机的待推送账本记下产生它们的运行，推送后为它们代为上报 `pushed`（出处不丢）。
   - RunSpec 里有 `rescue_branches`（之前推送冲突留下的，见下）→ 依次合并进来（已合并、已删除的跳过）；有冲突就保留冲突状态、不再合并其余的，提示词会要求 Agent 先解决。
   - 触发原因是「合并冲突自动重开」（15 §5）→ 先把 `origin/<base_branch>` 合并进来，冲突同样留给 Agent。
2. **执行**：Agent 在 worktree 里改代码、提交（提示词里要求它提交、不要推送）。
3. **收尾**（成功、失败、被停止、被服务端终止都做；限时 5 分钟；守护进程崩溃重启时不做，改动留在 worktree 由下一次运行带上）：
   - 守护进程自己的 git 命令不读用户的全局 / 系统配置、不运行 hook、不用用户的凭据助手；推送令牌只经 `GIT_ASKPASS` 给这些命令，每条都带 `-c credential.helper=`，令牌绝不写进 URL、远端地址或任何凭据存储——否则用户配的 `credential.helper=store` 会把安装令牌存进 `~/.git-credentials`，用户自己的推送随后被当成 bot 而 403（`add-daemon-git-workspace` 决策 8）；
   - 还有未提交的改动 → 以 Agent 的名义自动提交一次（`BOS-12: uncommitted changes from run <id>`），保证改动不会丢；有未解决的合并冲突时不提交，只推已有的提交；
   - 有新提交 → 推送任务分支（推送令牌快过期就先发 `git_token` 换新的；网络失败时先用 `ls-remote` 确认是否其实已落地）；
   - 推送被拒（远端分支被别人动过）→ 不强推，改推到**救援分支** `<任务分支>-run-<run_id>`（新分支，一定能推上去），运行 `failed(push_conflict)`；服务端记下救援分支，下一次运行准备时合并它。改动不会只留在某台机器上；
   - 网络、权限导致推送失败 → 重试 3 次，仍失败则 `failed(push_failed)`，改动留在本机 worktree，重试优先派回同一运行时；
   - 上报 `pushed`（分支、`base_sha`、`head_sha`、提交列表、救援分支），服务端记在运行上（运行已被判结束的迟到推送同样记录），据此开 / 更新 PR（15 §3）。**推送成功之后**才上报 `finished(succeeded)`；CLI 本身失败的运行保持原失败原因，推送问题附在 `error` 里。
4. **清理**（`add-pr-reconcile-merge` 决策 16）：每次启动后第一次连接成功时与之后每 24 小时，守护进程列出 `work/` 下的 worktree，用 `cleanup_check`（协议 Vc）询问服务端；服务端只对「任务 VERIFIED / CANCELLED / REJECTED、没有排队或活跃的运行、推送过 GitHub 的任务当前 PR 已合并或关闭」的回答可删，并附上该任务推送过的提交与基础分支。守护进程只处理经路径与 git 元数据证实属于自己缓存布局的 worktree（目录不是符号链接，`.git` 指向 `repos/` 下的 bare 缓存且反向登记一致，检出的正是任务分支；用户仓库的 worktree 即使放在 `work/` 下也不碰），再在本机确认：不等待即可拿到 worktree 与仓库缓存的锁、待推送账本为空、worktree 干净且没有进行中的合并、`HEAD` 已包含在某个推送过的提交或远端基础分支里——全部满足才删除 worktree 与缓存里的任务分支（本地模式不碰用户仓库）；否则保留并记日志。bare 仓库保留。

**本地仓库模式**（`add-local-repositories`，15 §8）：准备与收尾与上面相同，只是「远端」换成机器上的用户仓库——先 fetch 到 `repos/local/<name>.git`，在缓存的任务 worktree 里执行；收尾不强推地把 `hm/<工作区 ID>/<ident>` 推进用户仓库（`--receive-pack` 里强制 `receive.denyCurrentBranch=refuse` 与不运行 hook，被拒推救援分支；准备与交付前都复核该仓库仍对本运行的工作区开放），只写 `refs/heads/hm/<工作区 ID>/…`，不动用户的工作区、暂存区、`HEAD` 与其他分支；没有令牌，不开 PR。

## 8. 监督树

```
HelmsmanDaemon.Supervisor
├── Config                      # 读 config.toml / 凭据
├── Detector                    # CLI 检测与定期刷新
├── Connection                  # Slipstream 客户端：join、claim、上报、接收 cancel/steer
├── RunSupervisor (DynamicSupervisor)
│   └── RunWorker × N           # 一次运行一个：准备 → 启动 CLI → 转发事件 → 收尾 → 上报
└── StateStore                  # 把在跑的运行写到 state/，崩溃重启后对账
```

`RunWorker` 是 `:temporary` 进程：崩了不自动重启（重复执行比失败更糟），由 `Connection` 把这次运行上报为失败，服务端决定是否重试。

## 9. 安全模型

与 multica 相同的出发点：**CLI 本身不提供沙箱**。Agent CLI 能读写运行它的那个操作系统用户能读写的所有文件、用这个用户的所有凭据、访问网络；CLI 的审批也被设为无人值守（Claude `bypassPermissions`、Codex 关闭沙箱与审批、Copilot `--allow-all`、Cursor `--force`）。

这意味着**Agent 和守护进程之间没有边界**：Agent 能读到 `~/.helmsman/credentials` 里的 `hmd_` 令牌，冒充守护进程去领这台机器能领的所有运行；也能读到别的任务的 worktree。本期守护进程只实现这一种模式（`isolation = none`）：CLI 和守护进程是同一个系统用户。所以：

- 运行时**只能绑定机器主人自己的 Agent**（12 §3.3）：机器主人只跑自己的 Agent，风险只落在自己身上。多人共用一台服务器时，用一个专用的 Helmsman 账号登录守护进程、以它创建 `access = workspace` 的 Agent（12 §3.3），并用一个专用的系统用户运行守护进程。
- `helmsman daemon start` 首次运行时打印这段安全说明（Agent 能做守护进程用户能做的一切），建议用专用系统用户运行。
- 守护进程用户与执行用户分开（`isolation = user`）、容器 / 虚拟机隔离，以及在此之上的「公开运行时」，都是扩展点（00 §10）。本期 `join` 不上报隔离模式；扩展时 `join` 新增隔离模式字段、协议升版本（按 §1 的版本协商，旧守护进程视为 `none`），服务端据此决定能否开放公开运行时。领取、事件、结束等其余消息不受影响。
- 建议运行守护进程的系统用户**不配置任何 GitHub 凭据**（§5），这样推送和合并只能经过 Helmsman。
- 登录时只为**勾选的工作区**注册运行时（12 §3.1），`hmd_` 令牌泄露的影响限于这些工作区。

Helmsman 自己能保证的：

- Agent 拿到的 `hmr_` 令牌只能以这个 Agent 的身份、在这次运行的能力范围内调 MCP（13 §2.3），运行结束即失效，冒充不了人或别的 Agent；
- Helmsman 签发的推送令牌不交给 Agent（§5），合并由服务端按策略执行（15 §4）；
- 每次运行有私有的临时目录，CLI 用 Helmsman 专用的配置目录，不读、不改、不污染用户自己的 `~/.codex` 等。
- Agent 配置里的 `env` 与 `extra_mcp_servers` 存在服务器上（加密），会下发到执行机器——不想离开本机的密钥不要写在那里，直接放在守护进程用户的环境里。供应商账号的密钥同样加密存在服务器上、随运行下发到所属用户自己的机器，只在 CLI 的进程环境里出现。
- CLI 自己的配置层级不归 Helmsman 管：机器上的 Claude Code 托管策略（managed settings）高于命令行，能改掉供应商账号的地址（凭据来源被改会被守卫拦下）；未绑定供应商账号的 Agent，仓库里的 `.claude/settings*.json` 能改它的供应商地址与凭据去向（`-p` 下不询问信任，00 §9.5）。只在可信的仓库与机器上运行。

## 10. 测试

- 适配器：把各 CLI 的真实输出录下来作为 fixture，测试解析结果；启动参数做快照测试。
- 默认测试**不**调用本机真实的 CLI：用测试里生成的假 CLI 脚本（按 fixture 回放输出、模拟挂起、模拟崩溃）。
- 真实 CLI 冒烟测试单独打 tag（`@tag :real_cli`），需要显式设置 `HELMSMAN_REAL_CLI=1` 才跑。
- 协议：服务端 Channel 测试 + 守护进程连本地服务端的端到端测试（假 CLI），覆盖领取、断线重连对账、租约过期、停止、重复上报。

# 14 · 守护进程（helmsman daemon）

> 装在执行机器上的 Elixir 程序：连上服务器、领取运行、调起本机的 Agent CLI、把过程和结果传回去。
> 和服务端在同一个仓库（`daemon/`），共享协议定义（`protocol/`），见 00 §5。

## 1. 分发与命令

- 打包：Burrito 打成单文件，目标 linux-x64、linux-arm64、macos-arm64、macos-x64；首期不支持 Windows。
  依赖里有原生代码（erlexec 的端口程序），所以每个目标在**对应平台的 CI runner 上原生构建**（`ubuntu-24.04`、`ubuntu-24.04-arm`、`macos-15`、Intel macOS），不走交叉编译。ERTS 从源码自建（`.tool-versions` 的 OTP，静态链接 OpenSSL 3，不用 Burrito 的 musl 预编译 ERTS——它的加载器放在 `/tmp`，可被其他本地用户抢先放置）；Linux 在 `debian:bullseye` 容器里构建，运行要求 glibc ≥ 2.31，macOS 要求 13+。版本与服务端相同（仓库根 `VERSION`），`helmsman --version` 输出版本、协议版本与目标。
- 安装：`curl -fsSL https://<server>/install.sh | sh`：脚本识别系统与架构，从服务端 `/downloads/daemon/<target>` 下载与服务端同版本的二进制并按 `.sha256` 校验，原子安装到 `~/.local/bin/helmsman`（`HELMSMAN_BIN_DIR` 可改；不用 `HELMSMAN_INSTALL_DIR`，那是 Burrito 覆盖载荷解包目录的变量），不需要 root、不自动重启已在运行的服务；也可从 GitHub Releases 下载。macOS 不签名公证（`curl` 下载不带隔离属性）。
- 服务端在 `join` 时检查守护进程的协议版本（§3）；不兼容时拒绝并提示升级，守护进程停止重连。

| 命令 | 作用 |
|---|---|
| `helmsman login --server URL` | 设备码登录，得到 `hmd_` 令牌（12 §3.1） |
| `helmsman daemon start [--foreground]` | 启动；缺省安装为后台服务并启动（Linux 写 systemd 用户服务，需要 `loginctl enable-linger` 才能不登录也运行；macOS 写 launchd 代理），服务环境 = 执行时的 `PATH` + `daemon.env`；只有安装后的二进制能装服务；没有 systemd 用户会话时用 `--foreground` 交给自己的进程管理器 |
| `helmsman daemon stop \| restart \| status [--json] \| logs [-f] [-n N]` | `stop` 停止并取消自启（运行中的运行由服务端按规则重试）；`restart` 先用当前二进制与 `PATH` 重写服务定义（升级后用它）；`status` 看服务、连接、在跑的运行与磁盘占用；`logs` 在 Linux 读 journald、macOS 读 `logs/daemon.log` |
| `helmsman runtimes` | 列出检测到的 CLI、版本、绑定的工作区 |
| `helmsman repos add <路径> --name <名字> --workspace <slug>… \| remove <名字> \| list` | 登记 / 移除 / 列出本机的本地仓库（15 §8） |
| `helmsman repos roots [add <目录> \| remove <目录>]` | 允许网页登记本地仓库的根目录（`[repos] allowed_roots`，只能在本机设置；为空即网页不能登记或移除，`add-local-repo-web-registration`） |
| `helmsman --version` | 版本、协议版本、目标平台 |
| `helmsman logout` | 先停后台服务，再吊销本机令牌、删除本地凭据（含钥匙串项） |

本地文件：

```
~/.helmsman/
├── config.toml           # 服务器地址、并发上限、工作根目录、[[local_repositories]]（本地仓库模式，15 §8）、[repos] allowed_roots（允许网页登记的根目录）
├── config.lock           # config.toml 读改写的建议锁（CLI 与网页登记共用，0600，从不删除）
├── credentials           # 服务器地址、daemon_id、签发时间（0600）；hmd_ 令牌：macOS 缺省在登录钥匙串（`[credentials] store`；每代一项，文件只记已提交 / 写入中 / 待删除的代次，崩溃后可恢复），其他平台在这个文件里
├── status.json           # 运行状态：PID、版本、连接、在跑的运行（0600，不含令牌；`daemon status` 读它）
├── daemon.env            # 可选：后台服务的环境变量（KEY=VALUE，0600），例如 CURSOR_API_KEY
├── logs/                 # macOS 后台服务的日志（10 MB × 5 轮转）；Linux 用 journald
├── service/              # macOS 后台服务定义的正本（启用时复制到 ~/Library/LaunchAgents，stop 时删除副本并持久停用）
├── machine_id            # 首次运行时生成的随机 ID
├── state/                # 当前运行的本地记录（崩溃恢复用）
├── repos/<host>/<owner>/<repo>.git     # 仓库的 bare 镜像缓存
├── repos/local/<name>.git              # 本地仓库模式：从机器上用户仓库 fetch 的缓存（15 §8）
├── work/<workspace_id>/<ident>/        # 任务的 git worktree，同一任务的后续运行复用（用不变的工作区 ID）
├── scratch/<workspace>/<ident>/        # 没有仓库的任务的工作目录，同样复用（CLI 按工作目录保存会话）
├── codex/                              # 只在守护进程配置 `[codex] home` 指向这里时使用的私有 CODEX_HOME（持久，会话恢复要用）；缺省 Codex 用用户自己的目录（§4，`update-codex-user-home`）
└── runs/<run_id>/                      # 单次运行的私有目录：MCP 配置、临时文件、原始日志
```

## 2. 启动与 CLI 检测

- 在 `PATH` 里找 `claude`、`codex`、`copilot`、`cursor-agent`，执行 `--version` 取版本；低于最低支持版本的标记为不可用并说明原因。
- 能列出模型的 CLI 顺便取模型列表（例如 `cursor-agent --list-models`），连同支持的推理强度（如 Claude 的 `--effort`），随注册上报，供界面下拉。
- 每 10 分钟重新检测一次；`helmsman daemon restart` 立即重测。
- 一个 CLI 都没有时拒绝启动，并提示去安装。
- 检测到 Codex、而所用的 Codex 目录（缺省为用户的 `~/.codex`，§4）没有可用的模型来源（未登录、选定的 provider 未定义或缺 `env_key` 变量）时，启动时打印一行提示；运行时照常上报为可用（同一运行时上绑定了供应商账号的 Agent 不受影响，`update-codex-provider-check`、`update-codex-user-home`）。原私有目录 `~/.helmsman/codex` 存在而未配置 `[codex] home` 时另提示一次。

## 3. 与服务端的协议

用 Phoenix Channel（WebSocket），客户端库是 Slipstream。只有一条连接，所有消息都走它，没有额外的 HTTP 轮询——断线时 Slipstream 指数退避重连，重连后做一次对账（下文 `join`）。

- Socket：`wss://<server>/daemon/socket/websocket`；`hmd_` 令牌放在请求头 `x-helmsman-token`（服务端用 `connect_info: [:x_headers]` 读取），**不放进 URL**——查询串会进代理和访问日志。`vsn` 参数是 Phoenix 自己的序列化版本，协议版本不用它。
- Topic：`daemon:<daemon_id>`（登录时与令牌一起拿到 `daemon_id`）；`join` 的负载带协议版本 `protocol`，服务端只接受 `HelmsmanProtocol` 声明的兼容范围，否则回复 `unsupported_protocol`（附服务端版本与升级地址）。消息结构、校验与编解码都在 `protocol/`（`add-daemon-protocol`）。

**守护进程 → 服务端**（都用带回复的 push，失败重发）。关于某条运行的消息，服务端只接受**领取它的那个守护进程**、且运行处于预期状态时的上报（13 §1「一条运行只会被领取一次」）；事件按 `(run_id, seq)` 去重：

| 消息 | 内容 / 回复 |
|---|---|
| `join` | 协议版本、机器信息、检测到的 CLI、本机认为仍在跑的运行。回复：`daemon_id`、每个工作区每个 CLI 的 `runtime_id`；需要立即终止的运行 |
| `sync` | 与 `join` 相同的机器信息与 CLI 列表：每 10 分钟重新检测后（§2）、收到 `config_changed` 后、`config.toml` 变化后（30 秒检查）、网页登记 / 移除成功后发送。协议 7 起 `join` / `sync` 带 `repo_registration`（是否有有效的允许根目录，不上报根目录本身）。回复同 `join` |
| `claim` | 无参数（空闲槽位由服务端算，13 §4.1）→ 运行描述列表（下表） |
| `starting` | `run_id`：工作目录已就绪，请求启动 CLI。回复 `proceed` 或 `abort`（13 §4.2） |
| `started` | `run_id, session_id?` |
| `events` | `run_id, [%{seq, type, data, at}]`，最多每秒一批、每批 ≤ 200 条。回复：已连续落库的最大 `seq`，守护进程据此丢弃缓冲 |
| `heartbeat` | 每 30 秒；所有在跑的运行的 `run_id, last_seq`。回复：服务端认为已结束、应立即终止的运行 |
| `steer_ack` | `run_id, feedback_id`：CLI 已把插话纳入当前会话（以适配器的确认为准）；与事件同一套重发，`finished` 在它得到回复之后才上报（13 §8） |
| `git_token` | `run_id`：请求新的推送令牌（安装令牌 1 小时过期，长任务结束时可能已失效） |
| `cleanup_check` | 协议 4（`add-pr-reconcile-merge`；版本累积：2 供应商账号、3 本地仓库、4 清理、5 供应商账号请求头、6 仓库的只读检出 `repo.mode = snapshot`（`add-autopilots`）、7 网页登记本地仓库（`add-local-repo-web-registration`））：1–500 个 `{workspace_id, ident}`。回复每项 `deletable`、`base_branch`、`pushed_heads`（§7 第 4 步） |
| `repo_status` | 协议 3：本地仓库模式下，`join` / `sync` 回复给出要检查的分支，守护进程 fetch 用户仓库后上报每个分支的提交是否已进入基础分支（15 §8） |
| `repo_browse_result` | 协议 7：对 `repo_browse` 的回送，`request_id`、根目录标签、候选仓库（相对路径、建议名字、已登记的名字，≤ 200）、`truncated` 或错误码（15 §8） |
| `repo_change_result` | 协议 7：对 `repo_register` / `repo_remove` 的回送，`request_id`、动作、名字、错误码（空 = 成功）；成功时先发 `sync` 再发它 |
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
| `repo_browse` / `repo_register` / `repo_remove` | 协议 7：机器主人在网页上列出允许根目录下的仓库 / 登记 / 移除本地仓库，带 `request_id`；守护进程在连接进程之外串行执行、从头校验，用上面两条结果消息回送（15 §8） |

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
| **Claude Code** | `claude -p --input-format stream-json --output-format stream-json --verbose --permission-mode bypassPermissions --strict-mcp-config --mcp-config <run_dir>/mcp.json --setting-sources user --add-dir=<work_dir> [--model] [--effort] [--resume <id>]`，环境变量 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`（只加载用户级设置，仓库的 `.claude/settings*.json` 不生效；仓库的 `CLAUDE.md` 经附加目录照常加载，`update-claude-setting-sources`） | stdin 写一帧 stream-json 用户消息，stdin 保持打开；收到 `result` 后关闭 stdin | `--mcp-config` 指向私有目录里的 JSON（HTTP 服务器 + `Authorization: Bearer ${HELMSMAN_RUN_TOKEN}`，CLI 展开环境变量，令牌不落盘；2.1.246 实测，`add-claude-adapter` 决策 16） | `--resume` | stdin 再写一帧用户消息；送达信号与关闭 stdin 的时机以实测为准，找不到可靠信号则不支持（`add-run-steering` 决策 12） |
| **Codex** | `codex app-server --disable shell_snapshot --disable shell_snapshot_v2`（stdio 上的 JSON-RPC：`initialize` → `thread/start` 或 `thread/resume` → `turn/start`；审批 `never`、沙箱 `danger-full-access`），环境变量 `CODEX_HOME` = 用户的 Codex 目录（继承的 `CODEX_HOME` 或 `~/.codex`；守护进程配置 `[codex] home` 时为该私有目录） | `turn/start` 的参数 | `thread/start` 的 `config` 写 `mcp_servers.helmsman = {url, bearer_token_env_var = "HELMSMAN_RUN_TOKEN"}`（streamable HTTP，令牌不落盘、不进命令行）。缺省用用户自己的 Codex 目录（`update-codex-user-home`，与 Claude 用 `~/.claude` 一致）：终端里配好的登录、provider、网关与请求头直接生效，托管会话出现在用户的 Codex 历史里；守护进程对该目录只读（不建、不写、不删）。该目录 `config.toml` 里的 MCP 服务器在托管运行里按名字设为不启用（运行时守卫兜底），用户自己定义了 `helmsman` 服务器时 CLI 不可用（会与注入的逐键合并）；用户目录不存在时 CLI 不可用；工作目录或仓库根有 `.codex/config.toml` 时拒绝运行（`workspace_prepare`，未信任的项目配置也会生效）。不支持 MCP prompts（提示词只依赖工具与资源） | `thread/resume` | 当前 turn 内追加输入（`turn/steer`），成功回复即送达（`add-run-steering` 决策 11） |
| **Copilot CLI** | `copilot --output-format json --allow-all --no-ask-user --disable-builtin-mcps --additional-mcp-config @<run_dir>/mcp.json (--session-id <新 UUID> \| --resume <id>) [--model] [--reasoning-effort] --no-auto-update --log-dir <run_dir>/copilot-logs`，环境变量 `COPILOT_HOME=<守护进程主目录>/copilot-home`（私有、持久，所有运行共用；会话存在这里）、`COPILOT_AUTO_UPDATE=false`，继承环境与 Agent `env` 里的其他 `COPILOT_*` 去掉（只留 `COPILOT_GITHUB_TOKEN`、`COPILOT_GH_HOST`、`COPILOT_PROVIDER_*`）；登录用用户的 `gh`（CLI 自己调用 `gh auth token`）或 `COPILOT_GITHUB_TOKEN`，用户 `~/.copilot` 里的自有登录不可用（1.0.96 实测，`add-copilot-adapter`） | stdin（写完关闭；不用 `-p`，没有单参数 128 KB 的上限） | `--additional-mcp-config @文件`（注意 `@` 前缀），请求头写 `${HELMSMAN_RUN_TOKEN}`（展开已实测；不能加 `--secret-env-vars`，它会破坏展开）、`disableToolCache: true`。它**追加**到 `$COPILOT_HOME/mcp-config.json`，所以私有目录里不能有任何用户配置（MCP、hooks、插件等文件；`config.json` / `settings.json` 只允许 CLI 自建的 `firstLaunchAt` 与空值，内联 `hooks`、`statusLine`、`trustedFolders` 等任何其他设置都算用户配置；有则 CLI 不可用，`add-copilot-adapter` 决策 16）；仓库的 `.mcp.json` / `.github/mcp.json` 与 hooks 只在目录受信任时加载，守护进程从不信任目录（`COPILOT_ALLOW_ALL=true` 会信任，所以不传）；运行时守卫：出现未配置的已连接 MCP 服务器即中止 | `--resume`（会话 ID 只在输出最后一行出现，所以新会话用 `--session-id` 预先指定） | 不支持（`-p` 模式忽略运行中的 stdin）→ 结束后续跑 |
| **Cursor CLI** | **缺省不启用**：守护进程配置 `[cursor] enabled = true` 才可用（团队管理员策略与仓库 `.cursor/hooks.json` 关不掉，`add-cursor-adapter` 决策 1）。`cursor-agent -p --force --output-format stream-json --sandbox disabled --disable-codebase-ref --disable-project-configs --model <模型或 auto> (--new-session-id <uuid> \| --resume <id>)`；环境变量 `HOME=<run_dir>/home`（每次运行一个私有 HOME，随运行删除；共用会让并发运行的 `mcp.json` 串用）、`CURSOR_CONFIG_DIR` / `CURSOR_DATA_DIR` = 同一根目录下的 `config/` / `data/`（持久）、`AGENT_CLI_CREDENTIAL_STORE=memory`；只用 `CURSOR_API_KEY` 登录（不读写任何 `auth.json`）；`[cursor] home_links`（缺省 `.gitconfig`）把真实 HOME 的条目链接进来（2026.10.01 实测） | stdin（写完关闭） | 写进这次运行私有 HOME 的用户级 `.cursor/mcp.json`（内容只来自本次运行描述；用户级不需要批准；请求头 `${env:HELMSMAN_RUN_TOKEN}` 展开已实测，令牌不落盘）。仓库的 `.cursor/mcp.json` 等需要批准、私有 `DATA` 里从不写批准记录，所以不会被连接；不用 `--approve-mcps`（会批准并持久保存仓库的服务器）；`--disable-project-configs` 防止仓库 `.cursor/cli.json` 挡掉 Helmsman 工具；检测时 `mcp list` 列出任何服务器（只可能是团队下发）即不可用；调用未配置的 MCP 服务器即中止 | `--resume`（不存在的 ID 会静默开新会话，所以启动前检查会话记录） | 不支持 → 结束后续跑 |

- 上表参数按本机现有版本核对过帮助信息（claude、codex-cli 0.161、Copilot CLI 1.0.95、cursor-agent 2026.04）。各 CLI 演进很快：每个适配器开工时先做一次实测，确认输出事件格式、MCP 注入、会话恢复、私有配置目录下的登录真的可用，再定稿适配器（Claude、Codex 的实测与决策见 `add-claude-adapter`、`add-codex-adapter`）。
  已知风险：`codex app-server` 在 0.162 里仍标为实验性，选它是因为结构化错误码、`turn/interrupt`、`turn/steer`（`add-codex-adapter` 决策 1），备选是 `codex exec --json`（不支持插话）；私有配置目录若同时保存会话（Codex 即如此），就必须持久而不是随运行删除，否则无法恢复会话——Copilot / Cursor 实测时同样确认；Copilot 已实测（`add-copilot-adapter`：私有持久的 `COPILOT_HOME` + `gh` 登录，不复制用户文件）；Cursor 也已实测（`add-cursor-adapter`：用户级配置只能靠换 `HOME` 隔离，Agent 的 shell 因此看到私有 HOME；它的 shell 工具在独立会话里运行，停止时要跟踪脱离进程组的后代，§6）。做不到隔离的 CLI，适配器就不启用（fail closed），而不是退回到加载用户全部 MCP。
- `custom_args` 追加在固定参数之后；协议相关的参数（`-p`、`--output-format`、`--input-format`、`--permission-mode`、`--resume`、`--mcp-config` 等）被剔除，并在运行事件里记一条警告。
- Claude Code 拒绝在 root 下用 `bypassPermissions`：守护进程以 root 运行时启动直接失败，提示换用普通用户（与 §9 的安全建议一致）。
- **供应商账号**（12 §2.2，`add-provider-accounts`）：RunSpec 带 `agent.provider_account` 时才生效，否则启动方式与上表逐字节相同。
  - Claude Code：用户 `settings.json` 的 `env` 高于进程环境，仓库的 `.claude/settings*.json` 更高，命令行 `--settings` 最高（托管策略除外）。所以加 `--settings <run_dir>/claude-settings.json`（0600，不含密钥、不含 `null`——含 `null` 的设置文件会被整个静默忽略）：把决定地址、凭据、模型的全部变量先置空串再写入账号的地址与模型映射，顶层 `model` 同样覆盖，`apiKeyHelper` 改为 `printenv HELMSMAN_PROVIDER_API_KEY`（设置文件的 `env` 不展开变量，helper 让密钥只留在进程环境里）。不换 `CLAUDE_CONFIG_DIR`：那样用户的登录、hooks、会话都不加载，仓库设置仍能改地址。守卫：初始化行的 `apiKeySource` 不是 `apiKeyHelper` 就中止运行。
  - Codex：所用 Codex 目录（缺省为用户的）`config.toml` 的 `model_provider` 高于 `OPENAI_*` 环境变量，`-c` 高于 `config.toml`，`-c` 对已有 id 逐键合并。所以用保留 id：`-c model_provider="helmsman_account" -c model_providers.helmsman_account={base_url=…, wire_api="responses", env_key="HELMSMAN_PROVIDER_API_KEY"}`；专用 `config.toml` 定义了这个 id 时 CLI 不可用；`thread/start` 回复的 `modelProvider` 不是它就中止。账号带自定义请求头时同一个 `-c` 加 `env_http_headers`（名字 → `HELMSMAN_PROVIDER_HEADER_<i>`），值只在进程环境里，不用会把值放进命令行的 `http_headers`（`add-provider-account-headers`）。
  - Codex 启动前检查模型来源（`update-codex-provider-check`，`update-codex-user-home` 改为针对所用目录；顶层旧式 `profile` 使检测不可用，`app-server` 不选用 profile）：绑定了账号、按 CLI 优先级算出的有效 provider 不是 `openai`（Agent 参数里最后一个 `model_provider` 高于所用目录配置顶层的；它必须是内置的本地 provider（`ollama`、`lmstudio`）、在 Agent 参数里定义、或在所用目录配置里定义且 `env_key` 变量存在，`update-codex-user-home` 决策 5）、或在所用目录下 `codex login status` 已登录，任一成立才启动（0.162.1 的缺省 provider 不读 `OPENAI_API_KEY` 等环境变量，API key 要用 `codex login --with-api-key` 存进所用目录）；全部明确不成立时不启动，运行以 `provider_auth` 失败（不自动重试），错误说明怎样配置——否则缺省的 OpenAI provider 在连不上时会一直重试，把任务占住半小时以上。判断不了时照常启动。
  - 绑定账号时 `custom_args` 里改供应商的参数（Claude 的 `--settings`，Codex 的 `-c model_provider*`）被剔除（Claude 的 `--setting-sources` 无论是否绑定都剔除）；未绑定账号而 Agent `env` 里有供应商变量时，运行事件里警告（只列变量名）。

**输出归一化**：各适配器把 CLI 的输出解析成同一组事件——`text`（助手文本，增量合并）、`thinking`、`tool_call`（名称、参数摘要）、`tool_result`（截断到 16 KB）、`usage`、`session`（会话 ID）、`result`（最终输出、是否成功）、`error`（附原因码，13 §5）。原始输出另存在 `runs/<run_id>/raw.log`，7 天后清理，排查时用。

## 5. 运行环境

- 工作目录：有仓库时是任务的 worktree（§7）；自动化「仅运行」的项目绑定了仓库时是只读检出 `runs/<run_id>/checkout/`（§7）；没有仓库时，有任务的用 `scratch/<workspace>/<ident>/`（同一任务复用，会话才能恢复），无任务的用 `runs/<run_id>/scratch/`。
- 环境变量：**清理后的**继承环境 + `GIT_TERMINAL_PROMPT=0` + Agent 的 `env`，再加上下表；一律以「清空后整体传入」的方式启动子进程（erlexec 的子进程继承的是 erlexec 启动时的环境快照，事后删 BEAM 的环境变量清不掉，`update-daemon-env-scrub`）：
  - 清理（守护进程启动时、每个子进程——CLI、守护进程自己的 git、版本探测、`ps` / `kill` 等命令——每次启动时都按同一规则 `HelmsmanDaemon.Env` 清理）：去掉继承来的全部 `GIT_*`（被注入的配置 `GIT_CONFIG_*`、凭据弹窗 `GIT_ASKPASS`、改写仓库位置的 `GIT_DIR` / `GIT_WORK_TREE` 等、改写执行程序的 `GIT_EXEC_PATH` / `GIT_SSH_COMMAND` 等、跟踪输出）、`SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE`、全部 `VSCODE_*`（`VSCODE_GIT_IPC_HANDLE` 与 askpass 会让 Agent 经 VS Code 借用用户的 GitHub 登录，`VSCODE_IPC_HOOK_CLI` 能操纵用户的编辑器）；子进程另去掉继承来的 `HELMSMAN_*`。启动时打印被忽略的变量名（不含值）。
  - 保留其余全部（`PATH`、`HOME`、语言、代理、`SSH_AUTH_SOCK`、机器主人自己放进环境的令牌）：CLI 要靠它们联网与认证；Agent 能用守护进程用户的凭据见 §9。用户长期的 git 设置在 `~/.gitconfig` 里，Agent 的 git 照常读取；Agent 的 `env` 可以明确设置 `GIT_*`。
  - `GIT_TERMINAL_PROMPT=0`：守护进程在终端前台运行时，Agent 的 git 缺凭据也不会在终端上提示、卡住。

| 变量 | 值 |
|---|---|
| `HELMSMAN_RUN_TOKEN` | `hmr_` 令牌（只给 MCP 用） |
| `HELMSMAN_PROVIDER_API_KEY` | Agent 绑定了供应商账号时的密钥（12 §2.2），只给 CLI 的认证用（Claude 的 `apiKeyHelper`、Codex 的 `env_key`） |
| `HELMSMAN_SERVER_URL` / `HELMSMAN_RUN_ID` / `HELMSMAN_TASK` | 供 Agent 或脚本参考 |
| `TMPDIR` | `runs/<run_id>/tmp` |
| `CODEX_HOME` / `COPILOT_HOME` / `CURSOR_CONFIG_DIR` / `CURSOR_DATA_DIR`（及 Cursor 的 `HOME`） | 各 CLI 私有的配置目录：`CODEX_HOME` 缺省是用户自己的 Codex 目录，配置 `[codex] home` 时是该私有目录；`COPILOT_HOME` 是守护进程主目录下的 `copilot-home`；Cursor 的在守护进程主目录下的 `cursor/`；都持久，会话恢复要用（§4） |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`（及 `GIT_COMMITTER_*`） | 有仓库时：Agent 名与 `<agent>@agents.<服务器域名>`（Agent 名中的 `/` 等字符换成 `-`），提交记录能看出是哪个 Agent 写的 |

- **推送用的 GitHub 令牌不给 Agent**：它只在守护进程自己执行 `git fetch/push` 时通过 `GIT_ASKPASS` 临时提供，不进 CLI 的环境。
  但这**不等于** Agent 推不了代码：机器用户自己配置的 SSH 密钥、`gh` 登录，Agent 照样能用。要让「推送和合并只能经过 Helmsman」真正成立，按 §9 用一个**没有配置任何 GitHub 凭据**的专用系统用户运行守护进程。
- 关掉 CLI 自带的、可能带写权限的集成：Copilot CLI 加 `--disable-builtin-mcps`（否则内置的 GitHub MCP 会用用户的 GitHub 身份）并用私有、不含用户配置的 `COPILOT_HOME`，从不信任工作目录；Claude 用 `--strict-mcp-config` 只加载我们给的 MCP；Codex 加载用户的 Codex 配置，但其中的 MCP 服务器在托管运行里按名字设为不启用、Helmsman 的 MCP 由 `thread/start` 注入、意外加载的 MCP 服务器由运行时守卫中止运行，项目里另有 `.codex/config.toml` 时不运行，并一律以 `--disable shell_snapshot --disable shell_snapshot_v2` 启动（否则 CLI 把整个进程环境——运行令牌、供应商密钥、Agent 的 `env`——写进 `CODEX_HOME/shell_snapshots/`；只在 `[codex] home` 私有目录模式下启动前删除其中已有的快照，用户目录里的快照是用户自己的，不动，`add-provider-accounts` 决策 19、`update-codex-user-home` 决策 4）；Cursor 用私有的 `HOME` / `CURSOR_CONFIG_DIR` / `CURSOR_DATA_DIR`，Helmsman 放在私有 HOME 的用户级 `mcp.json`，从不批准仓库的服务器，并且缺省不启用。
- MCP 配置文件只放在私有目录（`runs/<run_id>/`，Cursor 是它的私有 HOME，0600），不写进仓库。
- 运行结束后删除 `runs/<run_id>/`（原始日志除外），worktree 保留给同一任务的下一次运行。

## 6. 进程管理

- 用 erlexec 启动 CLI：独立进程组（`{:group, 0}` + `:kill_group`），stdin / stdout / stderr 都接到 `RunWorker` 进程。BEAM 崩溃时 erlexec 会连带杀掉子进程，不留孤儿。
- **停止**：先走适配器的 `interrupt/1`（Codex 发 `turn/interrupt`；其他发 SIGTERM 给整个进程组），10 秒内没退出则 SIGKILL 整个进程组（CLI 拉起的 MCP 服务器、shell、测试进程一起结束）。
- **脱离进程组的后代**（`add-cursor-adapter` 决策 10，只在 Linux）：适配器声明 `track_descendants` 时（目前只有 Cursor：它的 shell 工具在独立会话里运行，结束 CLI 的进程组碰不到，CLI 退出后它们成为孤儿），`RunWorker` 在 CLI 环境里放一个每次启动独有的 `HELMSMAN_PROC_TAG`；同一用户下启动时环境带这个标记的进程（`/proc/<pid>/environ`，PID + 启动时间）与进程组成员同等对待。停止前与收尾时反复「扫描 → 信号 → 等待」，一次扫描什么都找不到才收尾与上报；读不到环境的同用户进程不算「无标记」：启动早于 CLI 的忽略，与成员有父进程 / 进程组 / 会话关系的算成员，其余不发信号但阻止清空，到期走清空超时处理（不做 git 收尾、保留记录）；崩溃恢复按记录的标记清理。不依赖父子关系与快照时机；故意清空环境的进程不在范围内（§9）。其他系统上声明它的适配器不可用。
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
4. **清理**（`add-pr-reconcile-merge` 决策 16）：每次启动后第一次连接成功时与之后每 24 小时，守护进程列出 `work/` 下的 worktree，用 `cleanup_check`（协议 4）询问服务端；服务端只对「任务 VERIFIED / CANCELLED / REJECTED、没有排队或活跃的运行、推送过 GitHub 的任务当前 PR 已合并或关闭」的回答可删，并附上该任务推送过的提交与基础分支。守护进程只处理经路径与 git 元数据证实属于自己缓存布局的 worktree（目录不是符号链接，`.git` 指向 `repos/` 下的 bare 缓存且反向登记一致，检出的正是任务分支；用户仓库的 worktree 即使放在 `work/` 下也不碰），再在本机确认：不等待即可拿到 worktree 与仓库缓存的锁、待推送账本为空、worktree 干净且没有进行中的合并、`HEAD` 已包含在某个推送过的提交或远端基础分支里——全部满足才删除 worktree 与缓存里的任务分支（本地模式不碰用户仓库）；否则保留并记日志。bare 仓库保留。

**只读检出**（`add-autopilots` 决策 13，协议 6）：运行描述的 `repo.mode = snapshot`（自动化「仅运行」，16 §2.2）时没有任务分支：准备时在仓库缓存锁下照常 fetch（GitHub 令牌只有 `contents: read`），`git worktree add --detach runs/<run_id>/checkout origin/<base_branch>`；收尾不自动提交、不推送、不上报 `pushed`，在缓存锁下 `git worktree remove --force` 并删除目录；不取任务 worktree 锁、不写待推送账本、不参与清理询问；崩溃遗留的由下一次准备的 `git worktree prune` 与运行目录清理处理。本地仓库模式同样，从本地缓存检出、从不交付回用户仓库。协议低于 6 的守护进程不会收到这种运行（服务端领取时直接以 `workspace_prepare` 失败并提示升级）。

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

Codex 因此以 `sandbox: danger-full-access` 运行，不用它自带的 bubblewrap 沙箱（需要 user namespace，很多主机与容器不可用，也给不了这里需要的边界）；app-server 启动时打印的 bubblewrap 错误日志与此无关、无害，检测也不探测沙箱（`update-codex-provider-check` 决策 5）。

这意味着**Agent 和守护进程之间没有边界**：Agent 能读到 `~/.helmsman/credentials` 里的 `hmd_` 令牌，冒充守护进程去领这台机器能领的所有运行；也能读到别的任务的 worktree。本期守护进程只实现这一种模式（`isolation = none`）：CLI 和守护进程是同一个系统用户。所以：

- 运行时**只能绑定机器主人自己的 Agent**（12 §3.3）：机器主人只跑自己的 Agent，风险只落在自己身上。多人共用一台服务器时，用一个专用的 Helmsman 账号登录守护进程、以它创建 `access = workspace` 的 Agent（12 §3.3），并用一个专用的系统用户运行守护进程。
- `helmsman daemon start` 首次运行时打印这段安全说明（Agent 能做守护进程用户能做的一切），建议用专用系统用户运行。
- 守护进程用户与执行用户分开（`isolation = user`）、容器 / 虚拟机隔离，以及在此之上的「公开运行时」，都是扩展点（00 §10）。本期 `join` 不上报隔离模式；扩展时 `join` 新增隔离模式字段、协议升版本（按 §1 的版本协商，旧守护进程视为 `none`），服务端据此决定能否开放公开运行时。领取、事件、结束等其余消息不受影响。
- 建议运行守护进程的系统用户**不配置任何 GitHub 凭据**（§5），这样推送和合并只能经过 Helmsman。
- 守护进程不会把**启动它的那个会话**的凭据通道（编辑器终端的 git askpass 与 IPC、被注入的 git 配置）交给 Agent（§5 的清理），但会把守护进程用户自己的凭据交给它；从服务管理器或干净的登录 shell 启动最稳妥。
- 登录时只为**勾选的工作区**注册运行时（12 §3.1），`hmd_` 令牌泄露的影响限于这些工作区。
- 网页登记本地仓库默认关闭：只有机器主人在本机设置了允许的根目录（`[repos] allowed_roots`）才开放，且只开放给机器主人自己的网页会话。服务端只能下发「根目录标签 + 相对路径」，守护进程逐级 `lstat`（根以下不跟随符号链接）、要求真实路径与 git 目录都在根内后才写入配置；服务端只知道「是否允许」，不知道根目录（`add-local-repo-web-registration`）。
- macOS 把 `hmd_` 令牌放进登录钥匙串，防的是它以明文出现在文件、备份与同步盘里；同一用户的进程（包括 Agent）仍能用 `security` 读出它，与上面「没有边界」一致。

Helmsman 自己能保证的：

- Agent 拿到的 `hmr_` 令牌只能以这个 Agent 的身份、在这次运行的能力范围内调 MCP（13 §2.3），运行结束即失效，冒充不了人或别的 Agent；
- Helmsman 签发的推送令牌不交给 Agent（§5），合并由服务端按策略执行（15 §4）；
- 每次运行有私有的临时目录；Copilot、Cursor 用 Helmsman 专用的配置目录。Claude Code 与 Codex 用用户自己的配置（`~/.claude`、`~/.codex`），守护进程只读、不改其中的文件，但其中的 hooks / `notify` 会在托管运行里执行（环境含运行令牌），托管会话也会出现在用户的 CLI 历史里；不想这样时 Codex 可配置 `[codex] home` 用私有目录。
- Agent 配置里的 `env` 与 `extra_mcp_servers` 存在服务器上（加密），会下发到执行机器——不想离开本机的密钥不要写在那里，直接放在守护进程用户的环境里。供应商账号的密钥同样加密存在服务器上、随运行下发到所属用户自己的机器，只在 CLI 的进程环境里出现。
- CLI 自己的配置层级不归 Helmsman 管：机器上的 Claude Code 托管策略（managed settings）高于命令行，能改掉供应商账号的地址（凭据来源被改会被守卫拦下）。仓库里的 `.claude/settings*.json` 不再生效（Claude Code 只加载用户级设置，`update-claude-setting-sources`），随之仓库的 `.claude/agents|skills|commands`、`CLAUDE.local.md` 也不加载，仓库的 `CLAUDE.md` 照常加载。只在可信的机器上运行。

## 10. 测试

- 适配器：把各 CLI 的真实输出录下来作为 fixture，测试解析结果；启动参数做快照测试。
- 默认测试**不**调用本机真实的 CLI：用测试里生成的假 CLI 脚本（按 fixture 回放输出、模拟挂起、模拟崩溃）。
- 敌意环境：CI 的守护进程质量门禁与服务端带守护进程的 E2E 都在 `scripts/hostile-git-env.sh` 下运行——它注入 §5 要清理的各类变量，能被调用的程序都是留下记录的金丝雀，任何一个被调用过就失败（`update-daemon-env-scrub`）。
- 真实 CLI 冒烟测试单独打 tag（`@tag :real_cli`），需要显式设置 `HELMSMAN_REAL_CLI=1` 才跑。
- 协议：服务端 Channel 测试 + 守护进程连本地服务端的端到端测试（假 CLI），覆盖领取、断线重连对账、租约过期、停止、重复上报。

# Helmsman daemon

守护进程在本机执行 Agent CLI，通过 Phoenix Channel 领取运行、发送事件和结果。
安装、登录、后台服务、`daemon.env`、钥匙串与卸载的用户文档见
[`docs/INSTALL.md`](../docs/INSTALL.md)。发布时打包成单文件二进制（Burrito），
以 `helmsman` 命令运行；在源码树里用 `mix helmsman …` 运行同一套命令。

从仓库根目录进入 `daemon/`，用项目的 Erlang / Elixir 版本运行：

```sh
mise trust
mise exec -- mix deps.get
mise exec -- mix helmsman --version
mise exec -- mix helmsman runtimes
mise exec -- mix helmsman login --server https://helmsman.example
mise exec -- mix helmsman logout
mise exec -- mix helmsman daemon start --foreground
```

命令（`helmsman` 换成 `mix helmsman` 即为源码树里的用法）：

| 命令 | 作用 |
|---|---|
| `helmsman --version` | 版本、协议版本、目标平台；`mix` 方式下目标为 `dev` |
| `helmsman login --server URL [--force]` | 设备码登录；已登录时加 `--force` 覆盖 |
| `helmsman logout` | 先停止并停用后台服务，再吊销本机令牌、删除本地凭据（含钥匙串项） |
| `helmsman runtimes` | 检测到的 CLI、版本与登录的工作区 |
| `helmsman daemon start [--foreground]` | 缺省安装并启动后台服务（只有安装后的二进制能装；`mix` 方式下以 2 退出）；`--foreground` 在前台运行 |
| `helmsman daemon stop` | 停止并取消自动运行 |
| `helmsman daemon restart` | 用当前二进制与 `PATH` 重写服务定义后启用并重启 |
| `helmsman daemon status [--json]` | 服务状态、连接、在跑的运行与磁盘占用；退出码 0 已连接、1 未连接、3 未运行 |
| `helmsman daemon logs [-f] [-n N]` | 最近 N 行（缺省 100）服务日志：Linux journald、macOS `logs/daemon.log` |
| `helmsman repos add PATH --name NAME --workspace SLUG...` | 登记本地仓库 |
| `helmsman repos remove NAME` / `helmsman repos list` | 移除 / 列出本地仓库；网页登记的项在 `list` 中带 `(added from the web)` |
| `helmsman repos roots` / `helmsman repos roots add DIR` / `helmsman repos roots remove DIR` | 列出 / 增加 / 删除允许网页登记的根目录（`[repos] allowed_roots`，最多 16 项，缺省为空即关闭） |

服务定义运行 `daemon start --foreground --service`：`--service` 读取 `daemon.env`，
macOS 上把日志写到轮转的 `logs/daemon.log`。服务相关的系统命令（`systemctl`、
`launchctl` 等）经可注入的执行器调用，测试里不会触碰真实的服务管理器。

登录会打印设备码和验证地址，按服务端间隔轮询。
注销时即使服务器不可达也会删除本地凭据，请在网页吊销机器。
已安装的服务管理器不可达、状态无法确认或服务停止失败时，注销会中止并保留凭据；
恢复服务管理器或手动停用服务后再试。
退出码：0 成功、1 一般错误、2 用法错误、3 认证失败 / 未运行 / 服务管理器不可用、4 协议不兼容、5 无可用 CLI。

`HELMSMAN_HOME` 覆盖默认的 `~/.helmsman/`：

```text
config.toml                 # server_url、max_concurrency (1–32，默认 4)、log_level、[credentials] store、[repos] allowed_roots、[[local_repositories]]
config.lock                 # 0600，config.toml 读改写的锁（CLI 与网页请求）；保持文件，内容为空
credentials                 # JSON，0600，原子替换，禁止放进代码仓库
credentials.lock            # 0600，跨 CLI 进程的凭据操作锁；保持文件，不含令牌
status.json                 # 运行状态（0600，不含令牌）；daemon status 读它，正常退出时删除
daemon.env                  # 可选，后台服务的 KEY=VALUE 环境变量（必须 0600）
logs/                       # macOS 后台服务日志（daemon.log 10 MB × 5；launchd.log）
service/                    # macOS 后台服务定义的正本
machine_id                  # 持久的随机机器 ID
state/<run_id>.json          # OS PID、PGID、已知组员身份；重启时先清理再连接
state/.security_notice_shown
runs/<run_id>/tmp/           # CLI 的 TMPDIR
runs/<run_id>/raw.log        # 原始输出，保留 7 天
scratch/<workspace>/<task>/  # 无仓库任务复用的工作目录
```

目录为 0700，凭据权限过宽时修正为 0600。配置缺失时采用默认值。

网页登记本地仓库（协议 7）：`[repos] allowed_roots` 列出允许的根目录（`~`、`~/…` 或绝对路径；
不能是 `/`，也不能在守护进程主目录内；格式错误时视为没有根目录）。只有根目录有效时，守护进程才
接受网页的列出、登记与移除请求，并在 `join` / `sync` 里只上报 `repo_registration: true`，从不上报
根目录本身。列出时不跟随符号链接、不进入隐藏目录与仓库，最多 4 层、200 个、10 000 个目录、5 秒。
登记时在 `config.lock` 内重新读取配置与根目录，逐级 `lstat` 校验路径，要求 git 目录也在根内，
写入真实路径与 `added_from = "web"`、`added_at`、`request_id`。建议只把专门放代码的目录设为根。
`[credentials] store` 为 `"file"`（Linux 唯一允许、缺省）或 `"keychain"`（macOS 缺省）。
文件存放时凭据格式是 `{"server_url":"https://…","daemon_id":1,"token":"hmd_…","issued_at":"2026-10-12T00:00:00Z","workspaces":[{"id":1,"slug":"bos","name":"Bosun"}]}`。
钥匙串存放时文件不含 `token`，改为 `"token_store":"keychain"`、`token_ref`（已提交的代次）、
`pending`（正在写入的代次）与 `stale_refs`（待删除的代次）；每一代令牌是一个通用密码项
（服务 `dev.helmsman.daemon`，账户 `<server_url> <daemon_id> <ref>`），用 `security -i`
从标准输入写入，令牌不出现在进程参数里。写入、崩溃恢复与迁移的规则见
`HelmsmanDaemon.Credentials` 的模块文档。
连接令牌只放在请求头，运行环境中的 `HELMSMAN_RUN_TOKEN` 是单独的 `hmr_` 令牌。
CLI 与守护进程使用同一个系统用户，能访问该用户的文件与凭据；建议用没有 GitHub 凭据的专用系统用户。
有仓库的运行目前以 `workspace_prepare` 失败；git 工作区由后续变更提供。

打包：每个目标在对应平台的机器上构建，Linux 在 `build/Dockerfile` 的 `debian:bullseye`
容器里（glibc 2.31 基线，需要 docker），macOS 原生（`MACOSX_DEPLOYMENT_TARGET=13.0`）。
OTP 由 `../scripts/build-erts.sh` 从源码构建（静态链接 OpenSSL），既用来跑 `mix release`
也是二进制里的 ERTS（`mix release` 在别的 OTP 上会拒绝）；Elixir 与 zig 由
`../scripts/build-tools.sh` 下载并按固定的 SHA-256 校验。缓存位置见 `build-daemon.sh` 开头。

```sh
../scripts/build-daemon.sh linux-x64 ../dist   # 产出 ../dist/helmsman-linux-x64 与 .sha256
```

服务器 `add-run-lifecycle` 的端到端测试可预先向临时目录写入上述凭据和配置，再启动测试环境：

```sh
MIX_ENV=test HELMSMAN_HOME=/absolute/path/to/test-home mise exec -- mix helmsman daemon start --foreground
```

test 环境自动注册 `HelmsmanDaemon.Adapters.Fake`，`HELMSMAN_FAKE_CLI` 可覆盖脚本路径。
Agent 的 `custom_args` 第一项选择 `test/support/fake_cli/scenarios/` 内的场景名或场景文件绝对路径。
脚本支持 `out`、`err`、`json`、`json_line_bytes`（流式生成指定字节数的 JSON 大行）、`sleep`、`spawn_child`、`ignore_term`、`echo_stdin`、`dump_env`、`dump_argv`、`exit`。
`spawn_child` 的 PID 写到 `FAKE_CLI_CHILD_PID_FILE`；JSON 形如 `{"type":"text","data":{"text":"hello"}}`。
测试代码可调用 `HelmsmanDaemon.TestSupport.write_credentials/4` 和 `start/1`。
`mix` 启动应用只启动依赖与空应用监督树，显式 `HelmsmanDaemon.start_daemon/1` 才连接服务器。

```sh
mise exec -- mix precommit
mise exec -- mix dialyzer
mise exec -- mix test --include macos   # 只在 macOS 上：临时钥匙串与日志文件的测试
```

进程组成员身份每 10 秒持久化；CLI 退出后清理全部已知组员，完成后才上报结果。
无法确认身份或清理超时时保留 state 记录并记录日志，供下次启动恢复；不会向身份不明的 PGID 发信号。

Claude Code uses the daemon user's own Claude configuration (`~/.claude`): login,
gateway, model, hooks and permissions from user-level settings apply to managed runs.
Every run starts with `--setting-sources user`, so the repository's
`.claude/settings.json` and `.claude/settings.local.json` do not load: a repository
cannot redirect requests or credentials, or add hooks and permissions (in `-p` mode
Claude Code does not ask whether to trust a directory). The repository's
`CLAUDE.md` and `.claude/CLAUDE.md` still load, through `--add-dir=<work dir>` with
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`. The repository's `.claude/agents/`,
`.claude/skills/`, `.claude/commands/` and `CLAUDE.local.md` do not load; put what
managed runs need in the user's `~/.claude/`. `--setting-sources` in Agent
`custom_args` is removed with a warning. Machine managed settings still apply.

Codex uses `codex app-server` (minimum 0.162.0). By default it uses the daemon's
inherited `CODEX_HOME`, or `$HOME/.codex`. It reads the owner's existing login,
provider, gateway and headers in place. The daemon does not create or modify this
user directory; run Codex once or `codex login` if it is missing. Codex itself saves
managed sessions and history there. To use a private directory, set an absolute
path or a `~/` path in the daemon's `config.toml`:

```toml
[codex]
home = "~/.helmsman/codex"
```

Helmsman creates an explicitly configured private directory with 0700. On migration
it prints a hint if the old `<HELMSMAN_HOME>/codex/` contains files. Sessions from
the old directory may fail to resume once; retry to start a new session.

User MCP servers are disabled by name in thread/start and thread/resume stdin.
Extra Agent MCP servers that collide with user names are dropped with a warning.
Rename any user MCP server named `helmsman`, or choose a private home: its settings
would merge with Helmsman's injected server. Invalid TOML, `project_root_markers`,
top-level legacy `profile`, and the reserved `model_providers.helmsman_account`
also make Codex unavailable. Unselected `[profiles.*]` tables are ignored;
Agent profile arguments are filtered. Project `.codex/config.toml` is rejected.

Before each run, Helmsman checks the bound account, effective `model_provider`
(last Agent override, then the selected home's config), and `codex login status`
in that same home. Custom providers must be built-in `ollama` / `lmstudio`, defined
in Agent arguments, or defined in the file. A file provider's `env_key` must exist
and be nonempty in the actual CLI environment; `requires_openai_auth` checks login.
Use Agent env or the environment that launches the daemon for credentials and
`env_http_headers`. A service manager does not inherit variables set only in an
interactive shell. Missing header variables produce a warning with variable names.
Config override values (`-c`) appear in process arguments.

Missing model sources fail before CLI launch with `provider_auth` and instructions.
A login probe that times out after 10 seconds or fails unexpectedly allows the run
with a warning. Codex 0.162.1 app-server's built-in OpenAI provider does not use
`OPENAI_API_KEY`, `CODEX_API_KEY`, or `OPENAI_BASE_URL` from the process environment;
use login in the selected home, a provider account, or a defined custom provider.
A missing source produces one startup hint without disabling the runtime.

User hooks and `notify` commands execute during managed runs and can see
`HELMSMAN_RUN_TOKEN`. The daemon user and Agent share the same trust boundary,
as with Claude hooks. User `shell_environment_policy` may filter variables such
as `GIT_AUTHOR_NAME` from Agent shell commands; check it when debugging commits.
Both shell snapshot features are disabled for every run. Old snapshots are cleaned
only in explicitly configured private homes; the user's own snapshots are preserved.

Both new and resumed threads use `approvalPolicy: never` and
`sandbox: danger-full-access`. They do not need bubblewrap or user namespaces.
The app-server startup message about bubblewrap is harmless in this mode;
stderr is retained for diagnostics and does not become a run error or event.

Development uses the same user home by default. `mix helmsman.dev_run --home <dir>`
reads `<dir>/config.toml`, including `[codex] home`:

```sh
mise exec -- mix helmsman.dev_run --provider codex --model gpt-6-luna --effort low --task DEV-9 --prompt "Reply exactly OK"
HELMSMAN_REAL_CLI=1 mise exec -- mix test test/helmsman_daemon/adapters/provider_real_cli_test.exs --only real_cli
```

The automated real CLI provider tests use temporary HOME / CODEX_HOME and a
loopback fake provider. They never use the owner's real Codex configuration.
The dev_run command accepts `HELMSMAN_RUN_TOKEN` from its process environment
so MCP tokens need not appear in shell arguments or URLs.
Codex startup disables update checking. Stdout messages are buffered intact up
to 32 MiB; larger messages stop the run with `cli_error`. Session storage remains
after runs finish so thread/resume works.

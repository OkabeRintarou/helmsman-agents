# Helmsman daemon

守护进程在本机执行 Agent CLI，通过 Phoenix Channel 领取运行、发送事件和结果。
当前提供前台运行；真实 CLI 适配器从后续 `add-claude-adapter` 开始交付。
生产配置暂未注册适配器，因此 `daemon start` 会提示安装并以 5 退出。

从仓库根目录进入 `daemon/`，用项目的 Erlang / Elixir 版本运行：

```sh
mise trust
mise exec -- mix deps.get
mise exec -- mix helmsman runtimes
mise exec -- mix helmsman login --server https://helmsman.example
mise exec -- mix helmsman logout
mise exec -- mix helmsman daemon start --foreground
```

登录会打印设备码和验证地址，按服务端间隔轮询；已登录时可用 `--force` 覆盖。
注销时即使服务器不可达也会删除本地凭据，请在网页吊销机器。
`daemon start` 与 `daemon start --foreground` 都在前台运行。
`daemon stop/restart/status/logs` 暂以 2 退出并提示后台服务随后续版本提供。
退出码：0 成功、1 一般错误、2 用法错误、3 认证失败、4 协议不兼容、5 无可用 CLI。

`HELMSMAN_HOME` 覆盖默认的 `~/.helmsman/`：

```text
config.toml                 # server_url、max_concurrency (1–32，默认 4)、log_level
credentials                 # JSON 设备令牌，0600，原子替换，禁止放进代码仓库
machine_id                  # 持久的随机机器 ID
state/<run_id>.json          # OS PID、PGID、已知组员身份；重启时先清理再连接
state/.security_notice_shown
runs/<run_id>/tmp/           # CLI 的 TMPDIR
runs/<run_id>/raw.log        # 原始输出，保留 7 天
scratch/<workspace>/<task>/  # 无仓库任务复用的工作目录
```

目录为 0700，凭据权限过宽时修正为 0600。配置缺失时采用默认值。
凭据格式是 `{"server_url":"https://…","daemon_id":1,"token":"hmd_…","issued_at":"2026-10-12T00:00:00Z","workspaces":[{"id":1,"slug":"bos","name":"Bosun"}]}`。
连接令牌只放在请求头，运行环境中的 `HELMSMAN_RUN_TOKEN` 是单独的 `hmr_` 令牌。
CLI 与守护进程使用同一个系统用户，能访问该用户的文件与凭据；建议用没有 GitHub 凭据的专用系统用户。
有仓库的运行目前以 `workspace_prepare` 失败；git 工作区由后续变更提供。

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
```

长期运行可手写 systemd user unit（保存到 `~/.config/systemd/user/helmsman.service`，将路径与用户名换成实际值）：

```ini
[Unit]
Description=Helmsman agent daemon
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/agent/helmsman-agents/daemon
Environment=HELMSMAN_HOME=/home/agent/.helmsman
ExecStart=/home/agent/.local/bin/mise exec -- mix helmsman daemon start --foreground
Restart=on-failure
RestartSec=5
KillMode=control-group

[Install]
WantedBy=default.target
```

由机器主人运行 `systemctl --user daemon-reload`、`systemctl --user enable --now helmsman`。

进程组成员身份每 10 秒持久化；CLI 退出后清理全部已知组员，完成后才上报结果。
无法确认身份或清理超时时保留 state 记录并记录日志，供下次启动恢复；不会向身份不明的 PGID 发信号。

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

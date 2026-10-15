> 路径相对 `daemon/`。前置：`add-provider-accounts` 已合入（满足）；若 `update-daemon-env-scrub` 先合入，决策 3 第 4、5 条用它构造的环境，否则用现有的 CLI 环境构造（合入后者时改为前者，写进其 impl-notes）。场景名指 `specs/` 下的同名场景。

## 1. 守护进程（hm-coder2）

- [x] 1.1 实测（codex-cli 0.162.1，空的临时 `CODEX_HOME`，本地假 Responses 服务）：`app-server` 下缺省 provider 是否使用 `OPENAI_API_KEY`、`CODEX_API_KEY`（以及 `OPENAI_BASE_URL`）；`codex login status` 在已用 `--with-api-key` 登录、未登录、`config.toml` 损坏三种情况下的退出码与输出。验证：结果写进 `reviews/impl-notes-1.md`（只记类别与退出码，不记密钥）；决策 3 第 4 条只计入实测确实使用的变量
- [x] 1.2 `Codex.Config.provider_source/3` 与 `prepare/3` 的接线（决策 3）。验证：`test/helmsman_daemon/adapters/codex_provider_source_test.exs` 按决策 6 表驱动；`test/helmsman_daemon/adapters/codex_prepare_test.exs` 覆盖 codex-adapter「启动前的模型来源检查」除「启动提示」外的全部场景（假 `codex` 脚本按 `login status` 参数返回 0 / 1 / 挂起，并把收到的 `CODEX_HOME` 写进文件供断言）；「什么都没配置」经 `RunWorker` 断言 CLI 没有启动、上报 `failed` / `provider_auth`、消息含专用目录路径
- [x] 1.3 启动提示（决策 4）。验证：`test/helmsman_daemon/detector_codex_hint_test.exs` 覆盖「启动提示」场景（`capture_io` / `capture_log`），已配置时不打印，同一次启动内重新检测不重复打印；上报的运行时状态不变
- [x] 1.4 沙箱断言（决策 5）。验证：`test/helmsman_daemon/adapters/codex_test.exs` 断言 `thread/start` 与 `thread/resume` 帧都带 `approvalPolicy: never`、`sandbox: danger-full-access`；stderr 送入一行 bubblewrap 错误日志不产生事件、`finish` 结果不变（codex-adapter「主机不能创建 user namespace」场景的单元部分）；真实 CLI 冒烟（`@tag :real_cli`）补断言线程回复的沙箱为完全访问且 shell 命令成功，本机跑一次，结果写进 impl-notes
- [x] 1.5 `mix precommit && mix dialyzer` 通过

## 2. 设计同步（hm-architect，本规格提交评审时完成）

- [x] 2.1 designs/14 §2、§4、§9 按 design「设计同步」修改。验证：`grep -n "login status\|bubblewrap" ../designs/14-daemon.md` 有结果

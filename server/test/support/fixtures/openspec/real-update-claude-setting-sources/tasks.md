## 1. 实测

- [x] 1.1 S0–S8、R0–R1（本机 Claude Code 2.1.246，临时目录与假服务，用户 `~/.claude` 只读）。验证：design「实测记录」逐项有做法、观察与结论，不含令牌、真实地址与家目录路径

## 2. 守护进程（hm-coder）

- [x] 2.1 `Claude.prepare`：固定参数在 `--mcp-config <路径>` 后加 `--setting-sources user`、`--add-dir=<工作目录>`；`Launch.env` 加 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`（与供应商账号的环境合并）（决策 1、2）。验证：`claude_prepare_test.exs` 覆盖「只加载用户级设置」的「固定参数与环境」、「启动参数与 MCP 注入」的「参数」；`claude_provider_test.exs` 绑定账号时 `--settings` 在 `--add-dir=…` 之后、环境同时有两个变量
- [x] 2.2 `custom_args` 的 `--setting-sources`（两种写法）一律剔除并进冲突警告；`--settings` 仍只在绑定时剔除；`--add-dir` 保留（决策 3）。验证：覆盖「过滤自定义参数」的「剔除」「设置来源」与「供应商账号覆盖」的「未绑定账号」
- [x] 2.3 Agent `env` 改不掉该变量。验证：`claude_run_worker_test.exs`（假 CLI 打印环境）覆盖「Agent 环境改不掉」
- [x] 2.4 真实 CLI 回归 `test/real_cli/claude_setting_sources_test.exs`（`@tag :real_cli`，不进 CI，决策 5）。验证：`HELMSMAN_REAL_CLI=1 mix test test/real_cli/claude_setting_sources_test.exs` 在本机通过，覆盖「仓库设置不生效」；结果写进 `reviews/impl-notes-1.md`（不记令牌、地址、家目录路径）
- [x] 2.5 文档：守护进程 README 的 Claude 一节说明只加载用户级设置、仓库 `CLAUDE.md` 仍加载、仓库的 agents / skills / commands / hooks / `CLAUDE.local.md` 不加载及理由（决策 4）。验证：README 出现这几点
- [x] 2.6 `cd daemon && mix precommit && mix dialyzer --force-check` 通过；`cd server && mix test test/e2e`（e2e）通过

## 3. 设计同步（hm-coder，留在工作区由 lead 提交）

- [x] 3.1 00 §9.5 该行标为已解决并指向本变更；14 §4 的 Claude 启动参数与供应商一节、§9 风险条目同步。验证：`rg -n 'setting-sources' designs/` 与本变更一致

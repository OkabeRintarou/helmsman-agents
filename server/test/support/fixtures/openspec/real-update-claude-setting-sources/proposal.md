## Why

00 §9.5 的已知问题（`add-provider-accounts` 预探查 P6b）：未绑定供应商账号的 Claude Agent，工作目录（即被指派任务的仓库）里的 `.claude/settings.json` / `settings.local.json` 能改 Claude Code 的请求地址、模型与凭据，`-p` 模式下不询问信任。本变更实测（design「实测记录」S0、R0）复现：仓库只写一个指向本机假服务的 `ANTHROPIC_BASE_URL`，用户网关的真实令牌就随请求发到了该地址。仓库的设置还能加 hooks、权限与 `apiKeyHelper`，绑定账号的运行同样会加载这些（只是地址与凭据被 `--settings` 覆盖）。

lead 决定：守护进程启动 Claude Code 时一律只加载用户级设置，仓库的 project / local 设置不生效。

## What Changes

- 每次启动 Claude Code 都加 `--setting-sources user`（绑定与未绑定账号一样）：用户的 `~/.claude/settings.json`（网关、模型、hooks、权限）照常生效；仓库的 `.claude/settings.json`、`.claude/settings.local.json` 不再加载；绑定账号的 `--settings` 覆盖文件仍然生效（实测 S6）；机器的托管策略不受影响。
- 仓库的说明文件照常加载：同时加 `--add-dir=<工作目录>` 与环境变量 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`，让仓库的 `CLAUDE.md`、`.claude/CLAUDE.md` 仍进入上下文（只加 `--setting-sources user` 时它们也不加载，实测 S1）。
- `custom_args` 里的 `--setting-sources`（两种写法，连同取值）一律剔除并记入冲突参数警告（多次出现时最后一个生效，实测 S7）；`--settings` 仍只在绑定账号时剔除。
- 随之不再加载的仓库内容（记入文档）：`.claude/agents/`、`.claude/skills/`、`.claude/commands/`、`CLAUDE.local.md`；`.mcp.json` 本来就因 `--strict-mcp-config` 不加载。
- 加回归：argv 断言的单元测试；一个 `@tag :real_cli`（不进 CI）的真实 CLI 回归——仓库设置指向本机假服务时请求不到假服务、运行成功、仓库 `CLAUDE.md` 生效。

## Capabilities

### New Capabilities
（无）

### Modified Capabilities
- `claude-adapter`：新增「只加载用户级设置」；修改「启动参数与 MCP 注入」「过滤自定义参数」「供应商账号覆盖」。

## Impact

- 守护进程（hm-coder2 负责的 `daemon/`，本变更由 hm-coder 实现）：`adapters/claude.ex` 的 `prepare`、参数过滤与 `Launch.env`；`claude_prepare_test.exs`、`claude_provider_test.exs`；新增 `test/real_cli/claude_setting_sources_test.exs`；守护进程 README 的 Claude 一节。
- 协议、服务端：不改。
- 设计：00 §9.5 该行标为已解决并指向本变更；14 §4 的 Claude 启动参数、§4 供应商一节、风险一节同步。

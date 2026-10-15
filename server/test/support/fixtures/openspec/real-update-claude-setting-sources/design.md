## Context

- `add-claude-adapter`：Claude Code 以 `-p` + stream-json 启动，`--strict-mcp-config` 只加载 Helmsman 的 MCP；工作目录是任务的仓库检出。
- `add-provider-accounts` 预探查 P6b：未绑定账号时仓库的 `.claude/settings*.json` 能改请求地址并带走用户的凭据；绑定账号时 `--settings`（命令行设置）高于项目与本地设置（P6），不受影响。00 §9.5 登记为未分配。
- lead 决定（2026-10-14）：启动 Claude Code 时一律只加载用户级设置（`--setting-sources user`），仓库的 project / local 设置不生效；先实测再实现。
- `add-claude-adapter` impl-notes-1：`--setting-sources ''` 会连用户设置一起屏蔽，返回 `Not logged in`；本变更只用 `user`。

## Goals / Non-Goals

**Goals**：仓库内容不能改变托管运行的请求地址、凭据、模型、hooks 与权限；用户自己的 Claude 配置（网关、模型、hooks）照常生效；仓库的 `CLAUDE.md` 照常作为说明加载；绑定账号的覆盖与守卫不变。

**Non-Goals**：机器的托管策略（managed settings，高于命令行，仍由机器主人负责）；限制用户级设置本身；为仓库的 agents / skills / commands 找替代加载方式；其他 CLI。

## 实测记录

hm-coder，2026-10-14，Claude Code 2.1.246。方法：`/tmp` 下的临时目录（不进仓库）里起一个 Python 假服务（127.0.0.1，一律回 401；只记录路径前缀、`Authorization` / `x-api-key` 按哨兵归类（非哨兵只记长度）、请求体的 `model`、请求体里是否出现几个标记词）；一个临时 git 仓库：`.claude/settings.json` 的 `env` 设 `ANTHROPIC_BASE_URL=<假服务>/project`、`ANTHROPIC_AUTH_TOKEN=proj-tok`、`ANTHROPIC_MODEL=proj-model`，`CLAUDE.md`、`.claude/CLAUDE.md`、`CLAUDE.local.md` 各含一个标记词，`.claude/agents/projagent.md`、`.claude/skills/projskill/SKILL.md`、`.mcp.json`（服务器 `projmcp`）；S 组用假的用户配置（临时 `CLAUDE_CONFIG_DIR` / `HOME`，`env` 设 `<假服务>/user`、`user-tok`、`user-model`，用户级 `CLAUDE.md` 含标记词），`env -i` 启动、`--no-session-persistence`，`-p "Reply exactly OK"`；R 组用用户真实的 `~/.claude`（只读，网关地址与令牌在用户 `settings.json` 的 `env` 里），不记录任何真实值。

| # | 做法 | 请求去向 / 凭据 / model；初始化行；上下文 | 结论 |
|---|---|---|---|
| S0 | 不加参数 | `/project`、proj-tok、proj-model；`mcp_servers` 含 `projmcp`，agents / skills 含仓库的；仓库与用户 `CLAUDE.md` 都在 | 复现 P6b |
| S0b | S0 + 仓库再放 `settings.local.json`（`/local`、local-tok） | `/local`、local-tok；三个仓库说明文件都在 | 本地设置高于项目设置，同样危险 |
| S1 | `--setting-sources user` | `/user`、user-tok、user-model；没有 `projmcp`、仓库 agents / skills；**仓库的 `CLAUDE.md` 也不加载**，只有用户级 `CLAUDE.md` | 参数有效；副作用：仓库说明丢失 |
| S2 | S1 + `--strict-mcp-config` | 同 S1 | 与 MCP 限制无冲突 |
| S3 | 不加参数 + `--strict-mcp-config` | `/project`；`mcp_servers` 为空 | `.mcp.json` 已由 `--strict-mcp-config` 屏蔽，与本变更无关 |
| S4 | S2 + `--add-dir=<仓库>` + `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` | `/user`、user-tok、user-model；`CLAUDE.md`、`.claude/CLAUDE.md` 在，`CLAUDE.local.md` 不在；agents / skills 不在 | 恢复仓库说明，且附加目录的设置**不**加载（含 `settings.local.json`） |
| S5 | S2 + `--add-dir=<仓库>`，不设该变量 | 同 S1（仓库说明不在） | 必须同时设变量 |
| S5b | `--add-dir <仓库>`（空格写法）后跟位置参数提示词 | 退出 1：`Input must be provided…` | `--add-dir` 可变参数会吞掉后面的非选项参数；固定参数用 `=` 写法 |
| S6 | S2 + `--settings <文件>`（地址 `/agent`、令牌 / 密钥置空、`apiKeyHelper` 输出 agent-key、model agent-model） | `/agent`、agent-key / agent-key、agent-model；`apiKeySource` = `apiKeyHelper` | 命令行设置在只加载用户级时仍生效，绑定账号的路径不受影响 |
| S7 | `--setting-sources user … --setting-sources user,project` | `/project` | 重复时最后一个生效：`custom_args` 里的必须剔除 |
| S8 | `--setting-sources=user` | `/user` | 等号写法同样有效 |
| R0 | 真实用户配置；另一临时仓库的 `.claude/settings.json` 只设 `ANTHROPIC_BASE_URL=<假服务>/project`；不加参数 | 假服务收到 `/project` 请求，`Authorization` 为一个 56 字符的非哨兵值（即用户网关的真实令牌） | **用户令牌被仓库引走**——问题在真实配置下成立 |
| R1 | 同一仓库，S4 的参数与变量，提示词要求回 OK 并写出项目说明里的标记词 | 假服务没有收到任何请求；运行成功，结果为 `OK` + 仓库 `CLAUDE.md` 的标记词；初始化行 `model` 等于用户 `settings.json` 的 `ANTHROPIC_MODEL` | 用户网关与模型照常生效，仓库说明照常生效 |

未实测：子目录里的 `CLAUDE.md`（Claude 读到该目录文件时才加载）在 `--setting-sources user` 下是否仍按需加载；`@` 引用的导入文件。不影响安全结论，记入风险。

## Decisions

1. **一律 `--setting-sources user`，绑定与未绑定账号一样**（S1、S6）。绑定账号时 `--settings` 仍覆盖地址与凭据、守卫不变；统一后仓库的 hooks、权限、`apiKeyHelper` 对两种运行都不再生效，参数构造也不分支。不用「未绑定时也钉住地址」：需要读并复制用户配置里的地址与凭据来源，仍挡不住仓库的 hooks 与权限。
2. **保留仓库说明**：固定参数加 `--add-dir=<工作目录>`，`Launch.env` 设 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`（S4、S5）。仓库的 `CLAUDE.md` 是托管运行理解项目约定的主要来源，丢掉它是行为倒退；附加目录只贡献说明文件，不贡献设置（S4）。`Launch.env` 高于 Agent 的 `env`，Agent 不能关掉它。用 `=` 写法，避免可变参数吞掉后面的参数（S5b）。
3. **`--setting-sources` 在 `custom_args` 里一律剔除**（两种写法，连同取值，S7），并入「Ignored conflicting Claude arguments」警告。`--settings` 未绑定时仍原样保留：它来自 Agent 的配置（工作区里有权编辑 Agent 的人），不来自仓库。`custom_args` 里的 `--add-dir` 原样保留（可与固定的那个并存）。
4. **随之不再加载的内容**：`.claude/agents/`、`.claude/skills/`、`.claude/commands/`、`CLAUDE.local.md`、仓库的 hooks / 权限 / 环境变量。守护进程 README 的 Claude 一节说明这一点与理由；需要这些能力的放进用户级配置（`~/.claude/`）。
5. **回归**：单元测试断言固定参数、环境变量与剔除；`test/real_cli/claude_setting_sources_test.exs`（`@tag :real_cli`，不进 CI）用真实 Claude、用户自己的配置，在运行的工作目录里放指向测试内本机监听端口的 `.claude/settings.json` 与含标记词的 `CLAUDE.md`，断言运行成功、监听端口没有收到连接、结果含标记词。

### 决策记录

（评审后补充）

## Risks / Trade-offs

- [仓库的 agents / skills / commands 不再生效] → 有意为之：它们与设置同属仓库可控内容；README 说明改放用户级配置。
- [`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` 是 CLI 的环境开关，将来版本可能改名] → 真实 CLI 回归会发现（结果不含标记词）；失效时只是仓库说明不加载，不影响隔离。
- [子目录 `CLAUDE.md` 的按需加载未实测] → 不影响隔离；如有差异记入后续。
- [托管策略仍高于命令行] → 不变，14 §9 风险条目保留这部分。

## Migration Plan

守护进程升级即生效，协议与服务端不变；已有会话可照常 `--resume`（设置来源不影响会话）。回滚即恢复原参数。

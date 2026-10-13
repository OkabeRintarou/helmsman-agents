# Helmsman 总体设计

> Helmsman（舵手）—— 面向「人 + Agent」协作的任务管理系统，用 Elixir / Phoenix 实现。
> 任务模型沿用 [bosun](https://github.com/TTalkPro/bosun)（项目 / 任务 / 状态机 / Feedback / Epic / 关联 / BQL）；
> Agent 执行模型参考 [multica](https://github.com/multica-ai/multica)：**服务端自动派发，执行机器上的守护进程调起 Agent CLI 写代码**；
> 再加上多用户、工作区、角色权限，以及 GitHub PR 与自动合并。

## 1. 定位：Agent 怎么干活

Helmsman **不直接调用 LLM API，也不保存模型密钥**。干活的是装在执行机器上的 Agent CLI（Claude Code、Codex、GitHub Copilot CLI、Cursor CLI），用的是这台机器上的登录和额度。

```
人在网页上把 BOS-12 指派给 Agent「keel/dev」
  → 服务端建一条「运行」，通知绑定的机器
  → 那台机器上的 helmsman 守护进程领取，准备好仓库的 worktree（分支 hm/7/bos-12），调起 claude / codex / …
  → Agent 通过 MCP 连回 Helmsman：读需求、领取任务、提问、写反馈，改代码并提交
  → 守护进程推送分支，服务端开 PR；Agent 把任务置为 DONE（附提交与测试结果）
  → 人或评审 Agent 验收（VERIFIED）→ CI 通过后服务端自动合并 PR
```

| | bosun | multica | **helmsman** |
|---|---|---|---|
| Agent 怎么开工 | 人手动启动 CLI，Agent 通过 MCP 自取任务 | 服务端派发，守护进程调起 CLI | 两种都支持：**托管 Agent** 自动派发（主要方式）；**外接 Agent** 同 bosun |
| Agent 怎么回写 | MCP | `multica` CLI + 运行级令牌 | MCP + 运行级令牌 |
| 触发方式 | — | 指派、@提及、对话、自动化、小队 | 指派、打回 / 重开、@提及、回答提问、回调提出方、依赖满足、小队、自动化 |
| 代码交付 | Agent 自己处理 | 每任务一个分支，人自己合并 | 每任务一个分支 + PR，验收后自动合并 |
| 用户 | 单人，无认证 | 多工作区、角色 | 多用户、工作区、角色 |
| 存储 / 前端 | Mnesia + bitcask / React | PostgreSQL / Next.js | PostgreSQL / Phoenix LiveView |

## 2. 目标与边界

| 要做（本期） | 不做（本期） |
|---|---|
| 账号：注册 / 登录（magic link + 密码）、邀请；工作区、成员、角色 | SSO / OAuth、计费、配额 |
| 项目、任务 `KEY-N`、Epic、任务关联（依赖 / 替代）；状态机 + 历史 + 完成证据 + 自验收规则 | 子任务树、看板拖拽、甘特图、自定义工作流 |
| Feedback：不可变、只追加、可修订 | 附件、图片托管 |
| **托管 Agent**：配置（CLI、模型、指令、绑定的机器、谁能触发）、守护进程、运行时 | 服务端直接调 LLM、内置聊天窗口 |
| **派发**：触发规则、排队与领取、重试、停止、运行中插话、实时执行记录 | 云端托管执行环境（只支持用户自己的机器） |
| **守护进程**（Elixir，单文件分发）：Claude Code、Codex、Copilot CLI、Cursor CLI | Windows 守护进程 |
| **GitHub**（github.com）：每任务一个分支与 PR，独立验收后自动合并，CI 失败 / 冲突自动打回给 Agent | GitHub Enterprise Server、GitLab / Gitea（以后按同一接口加） |
| **小队**（leader Agent 委派 / 拆分）、**自动化**（定时 / 手动 / webhook） | Skills 市场、跨工作区共享 Agent |
| MCP 工具全集（与 bosun 对齐，供托管和外接 Agent 共用） | 邮件 / IM 通知、对外 Webhook（后续，见 §10） |
| LiveView 界面，实时刷新；中英文全文检索、BQL、保存的筛选器 | |
| 工作区级 JSON 导出 / 导入（含从 bosun 导入） | |

任务、项目、Feedback **都不能删除**（同 bosun）：ID 会被 Agent、提交信息和 PR 引用。不用了就归档 / 撤销。

## 3. 技术选型

### 3.1 运行时

| 组件 | 版本 | 说明 |
|---|---|---|
| Elixir | 1.20.x | 用 `mise` / `asdf` 的 `.tool-versions` 锁定 |
| Erlang/OTP | 28.x | |
| PostgreSQL | 16+ | 开发用 `docker compose` 起 |

> 本机现有 Elixir 1.14 / OTP 25 太旧：Phoenix 1.8 要求 Elixir ≥ 1.15，anubis_mcp 要求 ≥ 1.18。M0 先升级工具链。

### 3.2 数据库：为什么选 PostgreSQL

| 维度 | **PostgreSQL** | SQLite（ecto_sqlite3） | Mnesia（bosun 的选择） |
|---|---|---|---|
| Ecto 支持 | 一等公民，默认适配器 | 良好 | 无，需要自己写存储层 |
| 多用户并发写 | MVCC + 行锁 | 单写者，Web 多用户下容易等锁 | 事务可以，但没有 SQL |
| 运行队列 | `FOR UPDATE SKIP LOCKED`，多个守护进程并发领取；Oban 也基于它 | 单写者，做不了并发领取 | 需要自己实现 |
| BQL 即席查询 | 编译成 SQL，过滤 / 排序 / 分页都在库里做 | 同左，函数少一些 | bosun 只能全表取出在内存里求值 |
| 全文检索 | tsvector + GIN，和业务写在**同一事务**里更新 | FTS5，中文要自定义分词器 | 要外挂索引（bitcask C++ NIF） |
| 部署成本 | 多一个服务 | 零依赖 | 零依赖 |

**结论**：多用户 Web 服务 + 运行队列 + 即席查询 + 全文检索 → PostgreSQL。

### 3.3 依赖

| 用途 | 选择 | 说明 |
|---|---|---|
| Web 框架 | Phoenix 1.8 + LiveView 1.2 | |
| 认证 | `mix phx.gen.auth`（1.8 版：magic link + 密码 + `Scope`） | 见 02 |
| 数据访问 | Ecto 3.14 + Postgrex | 枚举用 `Ecto.Enum` + 字符串列 + CHECK 约束 |
| 后台任务 | Oban | 运行的租约检查、GitHub 调用与合并、自动化调度、数据清理 |
| 敏感字段加密 | cloak_ecto | Agent 的 `env`、额外 MCP 配置、GitHub App 私钥 |
| MCP 服务端 | anubis_mcp 2.x（Streamable HTTP，Plug 集成） | LGPL-3.0，作为未修改的依赖使用；工具定义不绑定这个库，见 08 |
| GitHub | Req + JOSE（App JWT） | 见 15 |
| 定时表达式 | crontab + tz | 见 16 |
| Markdown | MDEx（comrak，GFM，ammonia 净化） | Mermaid 由前端 hook 渲染 |
| BQL 解析 | NimbleParsec | 见 10 |
| 全文检索 | PostgreSQL tsvector + GIN，Elixir 侧分词 | 见 10 |
| 实时 | Phoenix.PubSub + Phoenix.Presence | 页面刷新；守护进程在线状态 |
| UI | Tailwind v4 + daisyUI（Phoenix 1.8 默认） | |
| 邮件 | Swoosh | magic link、邀请 |
| **守护进程** | Slipstream（Phoenix Channel 客户端）、erlexec（子进程与进程组）、Burrito（单文件打包） | 见 14 |
| 测试 | ExUnit、Phoenix.LiveViewTest、StreamData、Req.Test | |
| 运维 | open_api_spex、hammer、logger_json | 见 11 |

## 4. 架构

```
 浏览器 (LiveView)       外接 Agent / 脚本             执行机器（用户自己的）
     │                    │ MCP / REST + hm_ 令牌       ┌──────────────────────────────────────┐
     │                    │                             │ helmsman 守护进程                     │
     │                    │                             │  ├ 领取运行、准备 worktree、推送分支    │
     │                    │                             │  └ 调起 claude / codex / copilot / cursor
     │                    │          Phoenix Channel     │        │ MCP + hmr_ 运行令牌           │
     │                    │      (hmd_ 令牌) ◄───────────┤        │                             │
     ▼                    ▼            ▼                └────────┼─────────────────────────────┘
 HelmsmanWeb.*Live   HelmsmanMCP   DaemonChannel                   │
     └────────────── %Scope{} ──────┴──────────────────────────────┘
                         ▼
 领域层 Helmsman.{Workspaces, Actors, Projects, Tasks, Feedback, Links, Search, BQL,
                  Agents, Runs, Dispatch, Squads, Autopilots, GitHub, Backup}
        │ Repo.transaction（触发器与写操作同一事务）      │ 提交后
        ▼                                              ▼
   PostgreSQL ◄── Oban（租约、合并、自动化）     PubSub ──► 页面实时刷新 / 通知守护进程
                       │
                       ▼
                 GitHub（App：PR、合并、CI 状态、webhook）
```

约定：

- **领域层对 HTTP / MCP / Channel 一无所知。** 公开函数第一个参数是 `%Scope{}`，返回 `{:ok, value} | {:error, reason}`。
- **错误映射集中两处**：`HelmsmanWeb.ErrorMapper`（HTTP）、`HelmsmanMCP.ErrorText`（给 Agent 看的英文提示）。
- **鉴权在领域层**：`Helmsman.Policy.authorize(scope, action, resource)`。
- **数据隔离**：所有查询都带工作区；跨表引用在数据库里用复合外键限定在同一工作区（01 §3）。
- **触发在写事务里**：引起派发的写操作（指派、迁移、Feedback、建链）在同一事务里插入运行，提交后再通知守护进程（13 §2）。
- **事务提交后才广播**，不在事务里调用 PubSub。
- **服务端决定，守护进程执行**：提示词、权限、重试、合并都由服务端决定；守护进程只负责在本机执行并如实上报。

## 5. 仓库结构

三个并列的 Mix 项目（不用 umbrella，各自独立发布）：

```
helmsman-agents/
├── .tool-versions  docker-compose.yml  .github/workflows/
├── protocol/                      # :helmsman_protocol —— 服务端与守护进程共享
│   └── lib/                       #   RunSpec、Channel 消息结构、事件类型、协议版本号
├── server/                        # :helmsman —— Phoenix 应用
│   ├── lib/helmsman/              #   领域层：accounts workspaces actors projects tasks feedback links
│   │                              #           search bql filters agents runs dispatch squads autopilots
│   │                              #           github backup  + policy.ex events.ex repo.ex
│   ├── lib/helmsman_mcp/          #   MCP 工具 / 资源 / 提示
│   ├── lib/helmsman_web/          #   LiveView、API、DaemonSocket / DaemonChannel、webhook
│   ├── assets/  priv/repo/migrations/  test/
├── daemon/                        # :helmsman_daemon —— 守护进程（Burrito 打包）
│   ├── lib/helmsman_daemon/       #   connection、detector、repo_cache、run_worker、adapters/*
│   └── test/                      #   假 CLI 与录制的输出 fixture
├── docs/AGENT-WORKFLOW.md / .en.md  # 面向 Agent 的协作规则，中 / 英两版（MCP 资源返回英文版）
└── designs/                       # 本目录
```

`server` 与 `daemon` 都以 path 依赖引用 `protocol`。`server` 内部用 `boundary` 库强制 `Helmsman` 不依赖 `HelmsmanWeb` / `HelmsmanMCP`。

## 6. 设计文档

| # | 文档 | 内容 |
|---|---|---|
| 01 | [01-data-model.md](01-data-model.md) | 全部表、约束、索引、事务与加锁 |
| 02 | [02-accounts-workspaces.md](02-accounts-workspaces.md) | 用户、工作区、成员、角色权限矩阵、Scope、Policy |
| 03 | [03-actors-tokens.md](03-actors-tokens.md) | Actor（人 / Agent / 小队 / 系统）、API Token、外接 Agent 的 MCP 身份 |
| 04 | [04-projects-tasks.md](04-projects-tasks.md) | 项目、任务、`KEY-N`、Epic、编辑与并发 |
| 05 | [05-task-status.md](05-task-status.md) | 状态机、历史、完成证据、自验收、自动流转 |
| 06 | [06-feedback.md](06-feedback.md) | 不可变 Feedback、修订链、待回答、@提及 |
| 07 | [07-links.md](07-links.md) | 依赖 / 替代、成环检测 |
| 08 | [08-mcp.md](08-mcp.md) | MCP 端点、认证、工具目录、资源、错误约定 |
| 09 | [09-web.md](09-web.md) | LiveView 页面、组件、Markdown / Mermaid、实时与 Presence |
| 10 | [10-search-bql.md](10-search-bql.md) | 中英文检索、BQL、保存的筛选器 |
| 11 | [11-backup-ops.md](11-backup-ops.md) | 导出 / 导入（含 bosun 迁移）、REST、发布与运维 |
| 12 | [12-agents-runtimes.md](12-agents-runtimes.md) | 托管 Agent 配置、谁能触发、守护进程与运行时注册、令牌 |
| 13 | [13-runs-dispatch.md](13-runs-dispatch.md) | 运行、触发规则、去重、领取、重试、提示词、停止与插话 |
| 14 | [14-daemon.md](14-daemon.md) | 守护进程：协议、CLI 适配器、运行环境、进程管理、分支、安全模型 |
| 15 | [15-github.md](15-github.md) | GitHub App、每任务分支与 PR、验收后自动合并、CI 失败自动打回 |
| 16 | [16-squads-autopilots.md](16-squads-autopilots.md) | 小队（leader 委派 / 拆分）、自动化（定时 / 手动 / webhook） |

## 7. 配置（环境变量）

| 变量 | 说明 |
|---|---|
| `DATABASE_URL` | Postgres 连接串 |
| `SECRET_KEY_BASE` | Phoenix 密钥 |
| `HELMSMAN_VAULT_KEY` | cloak_ecto 加密密钥（Agent 环境变量、GitHub 私钥等） |
| `PHX_HOST` / `PORT` | 对外域名 / 端口；守护进程和 GitHub webhook 都要能访问到 |
| `HELMSMAN_SIGNUP` | `invite`（缺省）\| `open` |
| `HELMSMAN_MAILER_*` | Swoosh 配置；不配时 magic link 打到日志（仅限 dev） |
| `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY` / `GITHUB_WEBHOOK_SECRET` / `GITHUB_APP_CLIENT_ID` / `GITHUB_APP_CLIENT_SECRET` | 可选；也可以在 `/admin/github` 用 manifest 流程创建（15 §1） |

## 8. 测试策略

| 层 | 方式 |
|---|---|
| 领域层 | ExUnit + SQL Sandbox（`async: true`）；状态机、BQL、合并决策表用 StreamData / 表驱动 |
| 派发 | 触发规则表驱动（事件 × 任务状态 × 执行方类型 → 是否建运行、合并到哪条）；并发领取用多个进程同时 `claim` 断言不重复 |
| Policy | 角色 × 动作 × 人 / Agent 全矩阵 |
| MCP | 直接调工具的 `call/2`；端到端用 Req 打 `/mcp` |
| 守护进程 | 假 CLI + 录制的输出 fixture；连本地服务端的端到端测试；真实 CLI 冒烟测试默认不跑（14 §10） |
| GitHub | `Req.Test` 打桩 + 本地 bare 仓库（15 §7） |
| LiveView | `Phoenix.LiveViewTest`；实时刷新用两个进程互相验证 |
| CI | GitHub Actions + postgres service：三个项目各自 `mix precommit`（compile --warnings-as-errors、format、credo、test）+ dialyzer；守护进程按平台矩阵构建 |

## 9. 里程碑与变更路线

派发是核心能力，排在检索、BQL 之前。每个里程碑拆成若干 OpenSpec 变更（`openspec/changes/<id>/`）：一个变更 = 一个分支，能独立实现、独立测试，验收方式写在各自的 tasks.md 里。

- 「负责」：**架构** = hm-architect 写规格、hm-coder 实现（必要的页面挂载点除外）；**前端** = hm-frontend 写规格并实现（`id` 以 hm-frontend 的变更为准）。
- 「依赖」列的编号指本表的 #；分号后是只影响验收或个别功能的软依赖。

### 9.1 路线

| # | 里程碑 | 变更 | 负责 | 范围 | 依赖 |
|---|---|---|---|---|---|
| 1 | M0 | `setup-project-skeleton` | 架构 | 工具链、protocol / server / daemon 三项目 + boundary、compose、CI、首个 migration | — |
| 2 | M0 | `add-user-auth` | 架构 | phx.gen.auth（magic link + 密码）、`display_name` / `instance_admin`、注册模式 | 1 |
| 3 | M0 | `add-web-ui-foundation` | 前端 | 视觉体系、外壳、基础组件、命令面板 | 1；认证页改样式需 2 |
| 4 | M1 | `add-workspaces-actors` | 架构 | 工作区、成员、Scope、Policy 矩阵、human / system actor、工作区锁、首用户引导 | 2 |
| 5 | M1 | `add-invitations-members` | 架构 | 邀请、改角色、移除成员、最后一个 owner 规则 | 4 |
| 6 | M1 | `add-api-tokens` | 架构 | `hm_` Token、Bearer 认证、身份解析（03 §4） | 4 |
| 7 | M1 | 工作区与设置页 | 前端 | 建 / 切换工作区、成员与邀请页、接受邀请页、Token 页 | 3、5、6 |
| 8 | M2 | `add-projects-tasks` | 架构 | 项目、任务 CRUD、`KEY-N`、版本检查、广播 | 4 |
| 9 | M2 | `add-task-state-machine` | 架构 | 状态机、`transition`、历史、完成证据、自验收 | 8 |
| 10 | M2 | 项目与任务页 | 前端 | 项目页、任务列表 / 详情、字段编辑、迁移按钮与证据面板 | 3、9 |
| 11 | M3 | `add-feedback` | 架构 | 不可变 Feedback、修订链、待回答、@提及解析（不触发）、迁移原因写入 | 9 |
| 12 | M3 | `add-markdown-rendering` | 架构 | 服务端 Markdown 渲染与净化、Mermaid 块输出、ident 与 @提及链接 | 8 |
| 13 | M3 | Feedback 界面 | 前端 | 时间线、写 / 修订面板、编辑与预览、Mermaid / 编辑器 hook、@补全 | 10、11、12 |
| 14 | M4 | `add-mcp-endpoint` | 架构 | anubis 接入、Tool 行为、会话守卫、Presence、ErrorText、身份工具 | 6 |
| 15 | M4 | `add-mcp-task-tools` | 架构 | 项目 / 任务 / 迁移 / 反馈工具、资源、prompt、AGENT-WORKFLOW；M4 手工验收 | 11、14 |
| 16 | M5 | `add-daemon-protocol` | 架构 | RunSpec、Channel 消息、事件类型、协议版本 | 1 |
| 17 | M5 | `add-agent-profiles-runtimes` | 架构 | `agent_profiles`（加密字段）、`access`、守护进程 / 运行时、设备码登录与 `hmd_` | 4 |
| 18 | M5 | `add-run-dispatch` | 架构 | 运行与运行令牌、入队合并、指派触发、授权来源 / 能力 / 防循环、`hmr_` Scope | 9、14、17 |
| 19 | M5 | `add-run-lifecycle` | 架构 | DaemonChannel、领取 / 启动前校验 / 心跳 / 租约 / 结束 / 停止 / 重试、提示词、任务副作用 | 11、16、18 |
| 20 | M5 | `add-daemon-runner` | 架构 | 守护进程：登录、连接、CLI 检测、RunWorker、崩溃对账、假 CLI、临时目录 | 16；端到端需 19 |
| 21 | M5 | `add-codex-adapter`、`add-claude-adapter` | 架构 | Codex 与 Claude Code 适配器，两个独立变更，先实测再实现。Codex 从 #29 提前；Claude Code 已改用用户的 z.ai 配置完成实测（`add-claude-adapter` 决策 16），两者都可用于 M5 验收 | 20；Codex 插话需 28 |
| 22 | M5 | Agent 与运行页 | 前端 | Agent / 运行时 / 设备码页、运行卡片、执行记录、停止 / 重试、指派确认；M5 端到端验收 | 10、17、19、45；验收需 21 中任一适配器（先是 Codex） |
| 23 | M6 | `add-github-app` | 架构 | App / manifest、安装令牌、webhook、仓库同步、项目绑定与合并设置 | 8 |
| 24 | M6 | `add-daemon-git-workspace` | 架构 | bare 缓存、任务 worktree、推送与救援分支、`git_token`、`runs` 上的推送记录（不建 `task_branches`） | 19、20、23 |
| 25 | M6 | `add-continuation-triggers` | 架构 | 打回 / 重开 / 重新提交 / 回答 / 回调提出方 / 提及（reply）与授权继承；CI 失败、合并冲突自动重开后的修复运行也由它入队 | 11、18 |
| 26 | M6 | `add-pr-reconcile-merge` | 架构 | ReconcilePR、合并策略 / 独立性（含推送链完整，15 §4.1）/ `verified_sha`、等运行收尾再合并、CI 失败 / 冲突自动重开；任务关闭后清理 worktree、本地分支与远端救援分支，本地仓库模式的 worktree 一并清理（需协议补充清理信号） | 24、25 |
| 44 | M6 | `add-local-repositories` | 架构 | 本地仓库模式：机器侧登记、项目绑定（一个项目一台机器）、只有那台机器能执行、先复制到缓存再把 `hm/<工作区 ID>/<ident>` 交付回用户仓库、合并状态（自动检测 + 人工标记）、协议 3（2 已由 #46 使用） | 17、19、24 |
| 45 | M5 | `add-run-read-models` | 架构 | #22 界面所需的只读领域函数：Agent 可派发性、任务的运行中 Agent、Agent 用量、Agent 视图的最近运行与权限、守护进程在线（`add-agents-runs-ui` 领域请求 R1、R5–R8） | 17、18、19 |
| 46 | M5 | `add-provider-accounts` | 架构 | 用户所属的供应商账号（地址、只写的加密密钥、模型映射），托管 Agent 选择其一；RunSpec 带账号、协议升版本、旧守护进程不领取；Claude 用 `--settings` 覆盖 + `apiKeyHelper` 读进程环境、Codex 用保留的 `model_providers.helmsman_account`，密钥不落盘，凭据来源不符即中止。先实测再实现 | 17、19、45；Claude 部分需 21 的 `add-claude-adapter`，Codex 部分需 `add-codex-adapter` |
| 47 | M5 | `add-provider-accounts-ui` | 前端 | 个人设置页 `/users/settings/provider-accounts`（列表、新建 / 编辑面板、删除确认与使用中的 Agent）；Agent 新建 / 编辑面板的「供应商账号」下拉（空 = CLI 默认登录）、详情页摘要（账号名 + 主机）与 `env` 提示 | 22、46 |
| 52 | M6 | `update-codex-user-home` | 架构 | 用户决定：Codex 缺省用用户自己的 Codex 目录（继承的 `CODEX_HOME` 或 `~/.codex`，守护进程只读），终端里配好的登录 / provider / 网关 / 请求头直接生效，会话进用户的 Codex 历史；私有目录改为可选（`[codex] home`）；用户配置里的 MCP 服务器在线程配置里按名字设为不启用（守卫兜底），用户定义了 `helmsman`、顶层旧式 `profile` 或目录不存在时不可用；模型来源检查按所用目录，未定义的自定义 provider / 缺 `env_key` 变量启动前 `provider_auth`；只在私有目录清理快照；会话恢复只看最近一次启动过 CLI 的运行（§9.5） | 21（`add-codex-adapter` 先归档） |
| 27 | M6 | `add-github-ui` | 前端 | GitHub 设置页、项目绑定 GitHub 仓库与合并设置、PR 卡片、重新验收 / 立即合并 / 重试、验收面板的合并预告；本地仓库部分拆到 #48（`add-github-ui` 决策记录） | 22、26 |
| 48 | M6 | `add-local-repositories-ui` | 前端 | 本地仓库模式的界面：项目绑定本地仓库（与 GitHub 切换）、本地分支卡片（审查命令、合并状态、标记已合并）、指派到别的机器时的提示、切换模式的提示（#44 决策 5、6、10、12）；在 #27 预留的位置上实现 | 27、44 |
| 28 | M7 | `add-run-steering` | 架构 | 插话、回执、兜底触发 | 19、21、25 |
| 29 | M7 | `add-copilot-adapter`、`add-cursor-adapter` | 架构 | 两个独立变更，先实测再实现，做不到隔离就不启用（`add-codex-adapter` 已提前到 21）。实测结论：Copilot 用私有持久 `COPILOT_HOME` + `gh` 登录可以隔离；Cursor 本机配置可隔离，但团队策略与仓库 hooks 关不掉，缺省不启用（`[cursor] enabled`），守护进程增加脱离进程组的后代跟踪 | 20 |
| 49 | M7 | `add-agent-conversation` | 架构 | 对话创建 Agent（12 §6）：创建对话（每人每工作区一个）、每轮一条无任务的设计运行（不恢复会话、服务端重放对话记录，能力 `read` + `design`，不重试）、草稿工具 `get_design` / `propose_agent` / `withdraw_agent`、用户改草稿、确认后一次创建多个 Agent、停止 / 排队超时 / 过期；小队接口定好，#34 落地。M6 之后，不阻塞首个可用版本 | 19、45、46、47 |
| 50 | M7 | `add-agent-conversation-ui` | 前端 | 对话创建页 `/w/:slug/agent-design`：起草 Agent 选择与可见性说明、对话（实时文本、停止、换起草 Agent）、实时草稿卡片（编辑 / 移除 / 敏感取值提示）、确认 / 放弃；运行列表的「创建对话」触发（`add-agent-conversation` 决策 14） | 22、47、49 |
| 51 | M7 | `add-provider-account-headers` | 架构 | 验收 C 拆出（`add-provider-accounts` 决策 20）：Codex 账号的自定义请求头（值只写、加密，经 `env_http_headers` + 进程环境下发，协议 5，旧守护进程不领取）；账号面板的请求头编辑由 hm-frontend 在同一变更里做。用户目录模式（#52）下用户网关已可用，本项用于同一机器上不同 Agent 走不同网关 / 分别计费；收紧检查已移到 #52 | 46、47、52 |
| 30 | M8 | `add-epics` | 架构 | Epic 校验、进度、自动级联 | 9 |
| 31 | M8 | `add-task-links` | 架构 | 替代 / 依赖、成环检测、`blocked`（只看状态） | 9 |
| 32 | M8 | `add-dependency-dispatch` | 架构 | `deferred` 运行、依赖满足触发、`satisfied?` 的 PR 规则与本地分支已合并规则（07 §3）、领取时复查 | 18、26、31、44 |
| 33 | M8 | 关联与协作界面 | 前端 | Epic 进度 / 步骤、关联与阻塞标记、插话勾选框、提及置灰说明 | 13、22、25、28、30、31 |
| 34 | M9 | `add-squads` | 架构 | 小队 actor、leader 运行、`delegate` / `delegate_done`、独立性扩展；对话创建小队（`propose_squad`、一次确认创建小队与新成员，16 §1.4）；Leader 不能创建 Agent（用户要求），成员可以是同一 CLI 上不同模型 / 推理强度 / 指令的多个 Agent | 25、26；对话创建小队需 49 |
| 35 | M9 | `add-autopilots` | 架构 | 定时 / 手动 / webhook、两种模式、`overlap`、失败停用 | 18、24 |
| 36 | M9 | 小队与自动化界面 | 前端 | 小队页、自动化页；对话创建小队（在 #50 的页面上加小队草稿） | 22、34、35；对话创建小队需 50 |
| 37 | M10 | `add-fulltext-search` | 架构 | 分词、检索列同事务写入、reindex、片段 | 11 |
| 38 | M10 | `add-bql-filters` | 架构 | BQL 解析 / 编译、bosun 兼容用例、保存的筛选器、MCP 查询工具 | 37；`run` / `pr` / `squad` 字段需 19、26、34 |
| 39 | M10 | 检索与查询界面 | 前端 | 命令面板的任务检索、列表搜索框、BQL 页、侧栏筛选器 | 3、38 |
| 40 | M11 | `add-rest-api` | 架构 | `/api/v1`、ErrorMapper、OpenAPI、限流 | 19、31、38 |
| 41 | M11 | `add-export-import` | 架构 | 快照导出、merge / replace 导入、actor 映射与认领、bosun 导入 | 31、38 |
| 42 | M11 | 数据设置页 | 前端 | 导出 / 导入页、认领导入的身份 | 7、41 |
| 43 | M11 | `add-release-distribution` | 架构 | release + Docker、健康检查、LiveDashboard、清理任务、守护进程多平台构建与安装脚本、后台服务（systemd / launchd）与 `daemon stop/restart/status/logs`、macOS 钥匙串 | 20；放最后 |

### 9.2 可以并行的部分

- 16、20、21 只依赖协议，可以和 M1–M4 同时做；17 只依赖 4，可以和 M2–M4 并行。
- 5、6、8 在 4 之后并行；9 与 12 并行；23 在 8 合并后即开工（已定，缩短到 M6 的时间），与 M3–M5 并行。
- 49、50 不依赖 M6 的任何变更，但按用户的安排排在 M6 之后，与 M7 其他变更并行。
- 25 只依赖 11、18，可在 M5 之后与 23、24 并行；30、31、37 在 M3 之后就能开工，不必等 M7；21 的两个适配器、29 的两个适配器互相并行。
- 前端变更与同里程碑的后端变更并行开发：前端先按后端变更的规格（领域函数签名、PubSub 消息）用桩数据写页面，后端合并后再接上。

### 9.3 里程碑完成标准

| 里程碑 | 完成标准 |
|---|---|
| M3 | 浏览器里能建项目 / 任务、走完整个状态机、写和修订 Feedback，两个浏览器窗口互相实时刷新 |
| M4 | 外接 Agent 用 Claude Code 手工跑通「建单 → 领取 → 提问 → 人在浏览器里回答 → 完成 → 人验收」（08 §6） |
| M5 | 网页上指派 → 本机 Agent CLI（Codex 或 Claude Code）自动开工 → 写反馈 → DONE，浏览器全程实时 |
| M6 | 「指派 → 运行 → 推送 → 开 PR → DONE → VERIFIED → CI 通过 → 自动合并」端到端跑通（15 §7）；CI 失败或合并冲突时任务自动重开，并以原指派的授权来源排队一次修复运行；评审 Agent 在自己的运行里验收后，要等该运行收尾才合并 |

自举（后续开发的工单放在 Helmsman 自己的项目里、由托管 Agent 执行）需要代码仓库，所以在 M6 之后进行；不在 M5 加「任意 git 远端、只推分支」之类不依赖 GitHub 的过渡模式。

### 9.4 约定

- **MCP 工具随领域分批交付**：M4 只交付领域已经存在的工具（身份 3 个、项目 4 个、任务 `list_tasks` / `get_task` / `create_task` / `update_task` / `list_my_tasks`、`transition_task`、反馈 3 个）；`link_tasks` / `unlink_tasks` 随 31，`search_tasks` 随 37，`query_tasks` 与筛选器工具随 38，`run_agent` / `list_runs` / `cancel_run` / `list_agents` 随 18–19，`delegate` 随 34。`list_tasks` 的 `query` 参数随 37 加入。
- **数据库迁移**：每张表在第一个用到它的变更里建、只建用到的列，后续用新 migration 加列（01 §5）。
- **后端与界面分开**：后端变更交付领域函数、PubSub 消息与必要的路由 / on_mount；页面、组件和交互在前端变更里。

### 9.5 已知问题与归属

开工前评审发现、尚未在设计里解决的问题，在对应变更的 design.md 里处理：

| 问题 | 归属 |
|---|---|
| ~~多条触发并入同一排队运行时，授权来源、`causal_agent_ids`、能力怎么合并；指派不进历史，`start: false` 之后的延续触发无处继承授权~~ 已解决：每条触发记自己的授权来源，合并保留最早的、领取时逐条复核；因果链取并集；能力领取时重算；授权记在 `task_grants`（13 §2.2–§3） | 18 `add-run-dispatch` |
| ~~`run_events` 按月分区，但主键 `(run_id, seq)` 不含分区键（PostgreSQL 不允许）；分区由谁预建~~ 已解决：不分区，按运行整块清理（13 §1） | 19 `add-run-lifecycle` |
| ~~插话的兜底触发在 13 §2 里没有对应的触发类型~~ 已解决：新发起触发 `steer`；被插话的运行成功结束且有回执才移除兜底（13 §2.1、§8） | 28 `add-run-steering` |
| ~~运行被判失败后，守护进程迟到的推送被拒，改动不进 `pushed_shas`~~ 已解决：`pushed` 不看运行状态，只看是否领取者当前代次的上报；`git_token` 在运行结束后 30 分钟内仍可续签（`add-daemon-git-workspace` 决策 4、5） | 24 `add-daemon-git-workspace` |
| ~~恢复会话失败（CLI 找不到会话）的运行以 `cli_error` 结束且 `session_id` 为空；`add-run-lifecycle` 决策 11 取「最近结束且 `session_id` 非空」的运行，下一次又会恢复同一个失效的会话，持续失败。方向：只看最近一次终态运行，其 `session_id` 为空就开新会话~~ 已解决：只看最近一次启动过 CLI 的已结束运行，它没有会话就开新会话（`update-codex-user-home` 决策 7） | 52 `update-codex-user-home` |
| 未绑定供应商账号的 Claude Agent，仓库里的 `.claude/settings*.json` 能改 Claude Code 的供应商地址与凭据去向（`-p` 下不询问信任；`add-provider-accounts` 预探查 P6b）。绑定了账号的不受影响。方向待定：未绑定时也只钉住地址（需要读用户配置），或对不可信仓库拒绝运行（类似 Codex 的项目配置检查） | 未分配 |

公开运行时的隔离问题（`isolation = user` 只有一个执行用户，不同用户的运行能互读 worktree 和 CLI 登录文件）已决定：本期不做公开运行时，守护进程只实现 `isolation = none`（12 §3.3、14 §9），两者推迟到扩展点（§10）。

## 10. 扩展点（不在本期）

- **更多代码托管**：GitHub Enterprise Server（按主机区分 App、安装、仓库 ID）、GitLab、Gitea / Forgejo，实现 15 的同一组接口（开 PR、查 CI、合并、webhook）。
- **执行隔离与公开运行时**：本期守护进程只有 `isolation = none`，运行时只能绑定主人自己的 Agent（12 §3.3、14 §9）。扩展时先做执行隔离——每个触发用户（或每次运行）一个独立的执行系统用户、容器或微型虚拟机，守护进程的令牌与文件对它不可读，不同用户的 worktree 与 CLI 登录文件互不可见——再在此基础上开放「公开运行时」（主人允许工作区成员把自己的 Agent 绑到这台机器）；届时 `daemons` 加 `isolation`、`runtimes` 加 `visibility`，`join` 新增隔离模式字段并升协议版本（旧守护进程视为 `none`；其余消息不变，14 §9）。云端托管执行环境（用户不用自备机器）也在这条线上。
- **Skills**：可复用的说明与脚本包，按 CLI 写到各自的约定目录（参考 multica）。
- **收件箱 / 通知**：`question` 待回答、被指派、合并失败 → 站内收件箱；邮件 / IM 用 Oban 投递。
- **对外 Webhook**：任务与运行事件推送到外部（Oban + 签名）。
- **多节点**：`dns_cluster` 组网；守护进程 Channel 与 MCP 会话天然可以分布在不同节点，MCP 会话表挪到 Postgres（03 §5）。
- **SSO**：`ueberauth` 接 GitHub / OIDC。

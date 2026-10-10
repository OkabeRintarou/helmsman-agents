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
  → 那台机器上的 helmsman 守护进程领取，准备好仓库的 worktree（分支 hm/bos-12），调起 claude / codex / …
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
├── docs/AGENT-WORKFLOW.md         # 面向 Agent 的协作规则（MCP 资源返回它）
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
| `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY` / `GITHUB_WEBHOOK_SECRET` | 可选；也可以在 `/admin/github` 用 manifest 流程创建（15 §1） |

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

## 9. 里程碑

派发是核心能力，排在检索、BQL 之前：

| # | 内容 | 文档 |
|---|---|---|
| M0 | 工具链、三个 Mix 项目骨架、docker-compose、CI、`phx.gen.auth` | 00 |
| M1 | 工作区、成员、邀请、角色、Scope、Policy；Actor 与 API Token | 01–03 |
| M2 | 项目、任务、状态机、历史；LiveView 页面 | 04、05、09 |
| M3 | Feedback（含 @提及解析）、Markdown、Mermaid | 06、09 |
| M4 | MCP 服务端：工具全集、资源、`docs/AGENT-WORKFLOW.md`；外接 Agent 用 Claude Code 手工跑通 | 08 |
| M5 | **派发最小闭环**：托管 Agent 配置、守护进程（登录、注册、Channel、领取）、Claude Code 适配器、运行与执行记录、指派触发、停止与重试。完成标准：网页上指派 → 本机 Claude Code 自动开工 → 写反馈 → DONE，浏览器全程实时 | 12、13、14 |
| M6 | **GitHub**：App 接入、仓库绑定、每任务分支、推送、PR、验收后自动合并、CI 失败 / 冲突自动打回 | 15 |
| M7 | 其余触发（打回 / 重开 / 提及 / 回答 / 回调提出方）、插话；Codex、Copilot CLI、Cursor CLI 适配器（开工前先实测各 CLI，见 14 §4） | 13、14 |
| M8 | Epic、关联、阻塞；依赖满足（代码任务 = 前置 PR 已合并）后自动开工 | 04、05、07、13 §2.4 |
| M9 | 小队、自动化 | 16 |
| M10 | 全文检索、BQL、保存的筛选器 | 10 |
| M11 | 导出 / 导入（含 bosun）、REST、`mix release` + Docker、守护进程安装脚本与发布 | 11、14 §1 |

M5 结束时系统就能「自举」：后续开发的工单放在 Helmsman 自己的项目里，由托管 Agent 自动执行。

## 10. 扩展点（不在本期）

- **更多代码托管**：GitHub Enterprise Server（按主机区分 App、安装、仓库 ID）、GitLab、Gitea / Forgejo，实现 15 的同一组接口（开 PR、查 CI、合并、webhook）。
- **更强的执行隔离**：守护进程的执行用户换成容器 / 微型虚拟机（14 §9）；云端托管执行环境，用户不用自备机器。
- **Skills**：可复用的说明与脚本包，按 CLI 写到各自的约定目录（参考 multica）。
- **收件箱 / 通知**：`question` 待回答、被指派、合并失败 → 站内收件箱；邮件 / IM 用 Oban 投递。
- **对外 Webhook**：任务与运行事件推送到外部（Oban + 签名）。
- **多节点**：`dns_cluster` 组网；守护进程 Channel 与 MCP 会话天然可以分布在不同节点，MCP 会话表挪到 Postgres（03 §5）。
- **SSO**：`ueberauth` 接 GitHub / OIDC。

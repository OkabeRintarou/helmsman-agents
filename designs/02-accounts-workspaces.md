# 02 · 账号、工作区与权限

> bosun 是单人无认证；Helmsman 的所有数据都属于某个**工作区**，人通过成员关系进入工作区，Agent 通过所属用户的 Token 进入（见 03）。

## 1. 账号

- 用 Phoenix 1.8 的 `mix phx.gen.auth Accounts User users`：magic link 登录 + 可选密码、确认邮件、改邮箱、敏感操作要求最近登录过（sudo mode）。
- 加一列 `display_name`。
- 注册模式 `HELMSMAN_SIGNUP`：
  - `invite`（缺省）：只能通过邀请链接注册；
  - `open`：任何人可注册。
- **引导**：库里还没有用户时，第一个注册的人不受 `invite` 限制，自动成为实例管理员和默认工作区的 owner。也可以用 `mix helmsman.bootstrap --email you@x.com --workspace acme` 直接创建。

## 2. 工作区

- `slug` 进 URL：`/w/:slug/...`；`name` 可改，`slug` 创建后可改（只有 owner），改了旧链接失效。
- 任何已登录用户都能创建工作区，自己是 owner。
- 本期**不做删除工作区**（和「任务不删除」一致）；以后要做就走「导出 + 软删除 + 定期清理」。

## 3. 成员与邀请

- 角色：`owner` / `admin` / `member` / `viewer`。
- 邀请：admin 以上生成邀请，得到一次性链接，7 天有效；配置了邮件就顺便发邮件。
  - **角色上限**：邀请的角色不能高于邀请人自己；只有 owner 能发 owner 邀请。
  - **绑定邮箱**：填了邮箱的邀请，只有该邮箱**已确认**的账号能接受；不填邮箱的是通用链接，谁拿到谁用（界面上提示风险）。
  - **一次性**：接受时 `UPDATE invitations SET accepted_at = now(), accepted_by_id = $u WHERE token_hash = $h AND accepted_at IS NULL AND expires_at > now() RETURNING *`，拿不到行即失效，不会被并发用两次。
  - 接受 = 登录或注册后加入工作区，同时创建该用户在本工作区的 human actor（03）。
- 移除成员：他的 Token 全部吊销，他名下的 Agent 全部停用（`disabled_at`）。历史记录里的名字保留。
- 至少保留一个 owner：改角色、移除成员、退出时，先 `SELECT … FOR UPDATE` 锁住该工作区**所有 owner 的 membership 行**再检查，两个 owner 同时降级自己时，后到的那个会看到对方已经不是 owner 而被拒绝。

## 4. 权限矩阵

| 动作 | owner | admin | member | viewer |
|---|:-:|:-:|:-:|:-:|
| 读项目 / 任务 / 反馈 / 检索 / BQL | ✓ | ✓ | ✓ | ✓ |
| 建任务、改字段、状态迁移、写反馈、建 / 删链 | ✓ | ✓ | ✓ | |
| 修订反馈 | 仅原作者（见 06） | | | |
| 建项目、改项目、归档 | ✓ | ✓ | | |
| 保存私有筛选器 | ✓ | ✓ | ✓ | ✓ |
| 保存共享筛选器 | ✓ | ✓ | ✓ | |
| 管理自己的 Agent 与 Token | ✓ | ✓ | ✓ | |
| 停用他人 Agent、吊销他人 Token | ✓ | ✓ | | |
| 触发托管 Agent（指派、@提及、手动运行） | 按 Agent 的 `access`（12 §2.1），与角色无关；小队按 16 §1.1；viewer 一律不能 | | | |
| 停用 / 归档他人的托管 Agent，改其描述、并发与超时（执行相关字段只有所属用户能改，12 §2） | ✓ | ✓ | | |
| 停止 / 重试运行 | ✓ | ✓ | 运行的授权来源用户（13 §2.2）或 Agent 所属用户 | |
| 看运行的执行记录 | ✓ | ✓ | ✓ | |
| 注册守护进程、管理自己的运行时 | ✓ | ✓ | ✓ | |
| 禁用他人的运行时 | ✓ | ✓ | | |
| 小队：建 / 改 | ✓ | ✓ | leader Agent 的所属用户 | |
| 自动化：建 / 改 | 有权触发该 Agent 的成员（16 §2.5） | | | |
| 连接 GitHub、项目绑定仓库、改合并策略 | ✓ | ✓ | | |
| 邀请 / 移除成员、改角色 | ✓ | ✓（不能动 owner，不能授予 owner） | | |
| 导出 | ✓ | ✓ | | |
| 导入（merge）、确认认领导入的身份（11 §1.2） | ✓ | ✓ | | |
| 导入（replace）、改 slug | ✓ | | | |

**Agent 的权限**：继承所属用户在该工作区的角色，但「管理类」动作（成员、Agent 配置、Token、运行时、小队、自动化、GitHub、导入导出、改 slug）只允许人来做。例外：托管 Agent 在运行中触发别的托管 Agent 或小队时，不按所属用户，而按这次运行的授权来源判断（12 §2.1、13 §2.2）。所属用户被降级或移除，Agent 立即跟着变：被移除时，他名下托管 Agent 排队中的运行全部取消，进行中的停止。

- 移除成员时，他的守护进程令牌对**这个工作区**失效，该机器在本工作区的运行时下线；机器上为其他工作区的工作不受影响。

## 5. Scope

phx.gen.auth 会生成 `Helmsman.Accounts.Scope`（只有 `user`），扩展为：

```elixir
defmodule Helmsman.Accounts.Scope do
  defstruct [:user, :workspace, :role, :actor, :via, :run]
  # via: :web | :mcp | :api | :run   （:run = 托管 Agent 用 hmr_ 令牌调 MCP，run 为当前运行）
end
```

| 入口 | 构造方式 |
|---|---|
| 浏览器 | `on_mount {HelmsmanWeb.UserAuth, :require_workspace}`：从会话取 user，按 `:slug` 取 workspace 与 membership，actor = 该用户在本工作区的 human actor |
| MCP | `HelmsmanWeb.Plugs.BearerAuth`：Token → user + workspace + role；actor 按 03 §4 解析 |
| MCP（托管 Agent 运行中） | 同一个 Plug 识别 `hmr_` 令牌：运行仍是 `claimed` / `running` 才有效；user = Agent 所属用户，actor = 该 Agent（固定），`run` = 当前运行，`via: :run` |
| REST | 同 MCP，actor 规则见 03 §4 |
| 守护进程 Channel | `HelmsmanWeb.DaemonSocket`：`hmd_` 令牌 → user + daemon；不构造工作区 Scope，领取到的每条运行再按运行所属工作区单独构造 |

不是成员 → 404（不暴露工作区是否存在）。

## 6. Policy

```elixir
Helmsman.Policy.authorize(scope, action, resource \\ nil) :: :ok | {:error, :forbidden}
```

- 一个模块，每个 action 一个函数头，规则就是上面的矩阵；`resource` 用于「仅原作者」「不能动 owner」这类判断。
- 领域函数第一步调用它，`with :ok <- Policy.authorize(...)`。
- 测试：角色 × 动作 × 人 / Agent 的全矩阵表驱动。

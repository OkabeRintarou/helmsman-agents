## Context

依据 14 §2（检测）、§4（Codex 一行与供应商账号）、§9（安全模型）、13 §5（失败原因与重试）；`add-codex-adapter` 决策 2（只读解析专用目录的 `config.toml`）、3（专用持久 `CODEX_HOME`，未配置时交给运行失败）、5（`custom_args` 白名单，`-c model_provider` 允许）、6（`thread/start` 带 `approvalPolicy: never`、`sandbox: danger-full-access`）、22（连续重试 5 分钟放弃）；`add-provider-accounts` 决策 8（绑定账号时用保留 provider `helmsman_account`）。实现已在 main（`fa7a723`）。

hm-architect 用本机 codex-cli 0.162.1 实测（2026-10-13）：
- 空的 `CODEX_HOME`：`codex login status` 输出 `Not logged in`、退出码 1；进程环境有 `OPENAI_API_KEY` 时同样（它只看保存下来的登录，不看环境变量）；`config.toml` 选了自定义 provider 时同样（它不看 provider）。所以「已登录」只能说明一种来源，其余要另外判断。
- `codex app-server` 在**启动时**、还没有任何线程时就打印 `ERROR codex_app_server: Codex's Linux sandbox uses bubblewrap and needs access to create user namespaces.`，与线程的沙箱模式无关。`add-codex-adapter` 实测 T5 与 `add-provider-accounts` 4.8 冒烟都在本机以 `danger-full-access` 实际写文件、执行 shell 成功。

## Goals / Non-Goals

**Goals:**
- 没有任何模型来源的 Codex 运行在启动 CLI 之前就失败，原因明确、不自动重试，不再占住任务半小时。
- 有模型来源的配置（账号、守护进程自己的登录、自定义 provider、API key 环境变量）一律不受影响；判断不了时宁可照常启动（由现有的放弃预算兜底）。
- 回答沙箱模式与是否探测沙箱。

**Non-Goals:**
- 不要求 Codex Agent 选账号；不把运行时标为不可用；不把「是否已配置」上报服务端或界面（要改协议，另议）。
- 不改「已配置但网络不通」时的放弃预算（`add-codex-adapter` 决策 22）。
- 不启用 Codex 自带的沙箱。

## Decisions

### 决策记录

1. **范围与归属**（hm-architect）：一个小变更，hm-coder2 实现；只改守护进程。
2. **不强制账号、不标不可用、启动前检查**（回答 lead 问题 1，hm-architect 定）：
   - 不强制选账号：机器主人可以在专用目录里为守护进程登录一次（ChatGPT 或 API key）或配置自定义 provider（`add-codex-adapter` 决策 3），这些 Agent 不需要账号。
   - 不把运行时标为不可用：一个 Codex 运行时上可以有多个 Agent，有的绑定了账号；运行时级别的「不可用」会拦住它们。
   - 改为**按运行**判断，在 `prepare/3` 里、启动 CLI 之前。
3. **模型来源检查** `Codex.Config.provider_source(spec, codex_home, env) :: {:ok, source} | {:error, :none} | {:unknown, reason}`（`reason` 是不含认证值的诊断，例如 `:timeout`、`:not_found`、`{:exit, 2}`）。先算出本次运行**实际生效**的 provider（与 CLI 自己的优先级一致：命令行 `-c` 高于专用目录的 `config.toml`，`add-provider-accounts` 决策 8；规格评审 1 P2），再判断：
   1. 运行描述带供应商账号 → `:account`（实际生效的是保留 provider `helmsman_account`）；
   2. 否则，有效 provider = 过滤后的 `custom_args` 里**最后一个**设置 `model_provider` 的 `-c` / `--config` 的取值；没有这样的参数时取专用目录 `config.toml`（决策 2 已有的只读解析）的顶层 `model_provider`；都没有时为 `openai`。有效 provider 不是 `openai` → `:custom_provider`。有效 provider 是 `openai` 时**不再**回头看被覆盖的值（例如参数显式选了 `openai`、文件里写着 `gateway`：本次运行用的是 `openai`），只继续下面两条；
   3. CLI 将得到的环境（`update-daemon-env-scrub` 之后的完整环境：清理后的继承环境 + Agent `env`）里，缺省 OpenAI provider 会读取的 API key 变量非空 → `:env`。哪些变量算数以实测为准（tasks 1.1：至少核对 `OPENAI_API_KEY` 与 `CODEX_API_KEY` 在 `app-server` 下是否被缺省 provider 使用，只计入确实使用的）。**实测结果（codex-cli 0.162.1，`reviews/impl-notes-1.md`）：集合为空**——缺省 provider 不读 `OPENAI_API_KEY`、`CODEX_API_KEY`、`OPENAI_BASE_URL`，也不接受命令行对 `model_providers.openai` 的覆盖；API key 要经 `codex login --with-api-key` 存进专用目录（第 4 条能识别）。所以这一条目前不会成立，保留它只为以后的 Codex 版本；
   4. `codex login status`（`CODEX_HOME` = 专用目录，环境同第 3 条，经 `Exec` 启动，超时 10 秒）退出码 0 → `:login`；退出码 1 → 本条不成立；超时、找不到程序、其他退出码 → `{:unknown, reason}`；
   5. 都不成立 → `{:error, :none}`。
   - `{:error, :none}` → `prepare/3` 返回 `{:error, {:provider_auth, message}}`，不启动 CLI；`message`（英文）：`Codex has no model provider for agent <名字>. Bind a provider account to the agent, or configure Codex for the Helmsman daemon once: CODEX_HOME=<专用目录> codex login, or set model_provider in <专用目录>/config.toml.` `provider_auth` 不自动重试（13 §5）。
   - `{:unknown, reason}` → 照常启动，`Launch.events` 加一条 `status` 警告 `Could not check the Codex login (<reason>); starting anyway.`（只有诊断，不含命令输出）；之后由放弃预算兜底。
   - 有效 provider 为 `openai` 而另配了 `OPENAI_BASE_URL` 网关等写法，仍按第 3、4 条判断。
   - 不读 `auth.json` 的内容或是否存在：登录也可能保存在系统钥匙串里，只有 `codex login status` 能统一判断。
4. **启动时的本地提示**：`Detector` 检测到 Codex 可用后，用决策 3 的第 2–4 条（没有运行描述与 Agent 参数：有效 provider 只看专用目录，环境为守护进程的清理后环境）判断一次；`{:error, :none}` 时向日志 / stderr 打印一行：`Codex is installed but not configured for the Helmsman daemon; Codex agents without a provider account will fail. Configure it with CODEX_HOME=<专用目录> codex login, or a model_provider in <专用目录>/config.toml.` 每次守护进程启动最多一次，不影响检测结果与上报。
5. **沙箱模式**（回答 lead 问题 2，hm-architect 定）：维持 `add-codex-adapter` 决策 6 的 `sandbox: danger-full-access` 与 `approvalPolicy: never`。理由：14 §9 的前提是 CLI 本身不提供隔离（Claude `bypassPermissions`、Copilot `--allow-all` 同理），Agent 需要在 worktree 里自由读写、跑测试、访问网络；Codex 的 `workspace-write` 需要 bubblewrap 与 user namespace，在很多 Linux 主机与容器里不可用，开了也只是部分隔离，给不了 14 §9 要的边界。真正的隔离仍是扩展点（`isolation = user`、容器）。
   - **不探测**沙箱可用性：`danger-full-access` 不使用 bubblewrap。app-server 启动时那行 bubblewrap 的 `ERROR` 日志与沙箱模式无关、无害；适配器照旧不把 stderr 变成事件（只保留最后 50 行），排查文档写明。
   - 守住这个前提的测试：Codex 的真实 CLI 冒烟（`@tag :real_cli`）断言 `thread/start` / `thread/resume` 的回复里沙箱为完全访问，且 shell 命令实际执行成功（`add-provider-accounts` 4.8 已有 shell 执行，补沙箱断言）。
6. **测试**：`provider_source` 表驱动，以「参数 × 文件 × 环境 × 登录」的组合覆盖有效 provider：文件 `gateway` + 参数 `openai` + 无密钥 + 未登录 → `{:error, :none}`；同上但有实测可用的密钥或已登录 → 启动；文件 `openai` + 参数 `gateway` → `:custom_provider`；参数先 `gateway` 后 `openai`（文件 `gateway`）→ 有效为 `openai`；只有文件 `gateway` → `:custom_provider`；`config.toml` 不存在；`login status` 的 0 / 1 / 超时 / 找不到；`login status` 用假 `codex` 脚本（按参数返回退出码，记录收到的环境：`CODEX_HOME` 为专用目录、没有被清理的变量）；`prepare/3` 为 `{:error, :none}` 时不启动 CLI、`RunWorker` 上报 `failed(provider_auth)` 且消息含专用目录路径；`:unknown` 时照常启动并有警告；启动提示用假 `codex` 覆盖打印与不打印。实测记录（tasks 1.1）写进 `reviews/impl-notes-1.md`。

### 设计同步（本变更一并修改 designs/）

- 14 §2：检测后对 Codex 的未配置提示；§4 Codex 一行：启动前的模型来源检查与失败原因；§9：Codex 以 `danger-full-access` 运行、不需要 bubblewrap，启动日志里那行无害。

### 评审记录

- 实测（hm-coder2，tasks 1.1）：缺省 provider 的环境密钥集合为空，决策 3 第 3 条按批准的条件不计入任何变量；`config.toml` 损坏时 `login status` 也退出 1，由已有的 `Config.validate` 在检查之前拦下（hm-architect 确认，不改规格）。

- 规格评审 1（hm-reviewer，P2，接受）：原决策 3 逐条看参数与文件，参数显式选 `openai` 时会回头接受文件里被覆盖的 `gateway`，仍放行缺省 OpenAI 的长时间重试。改为先按 CLI 的优先级算出有效 provider（账号 > 最后一个参数 > 文件 > `openai`），为 `openai` 时只看密钥与登录；`:unknown` 带脱敏的诊断原因。规格与 tasks 1.2 加组合回归。
- 规格评审 2（hm-reviewer）：通过，P2 关闭。

## Risks / Trade-offs

- [模型来源判断有误，把能跑的配置判成没有] → 只在第 1–5 条全部明确不成立时才失败；`login status` 判断不了时照常启动。误判的已知形态（例如以后 Codex 增加新的认证途径）由实测与 `real_cli` 冒烟发现，修 `provider_source` 一处。
- [有模型来源但网络不通] → 仍走放弃预算与 `provider_network` 重试，不在本变更。
- [每次运行多一次 `codex login status`] → 只在前四条都不成立时执行，约百毫秒。
- [`danger-full-access` 没有任何隔离] → 14 §9 的既定前提；建议专用系统用户。

## Migration Plan

只改守护进程，无数据迁移；部署即生效。

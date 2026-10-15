## ADDED Requirements

### Requirement: 启动前的模型来源检查

适配器 MUST 在启动 Codex 之前判断这次运行是否有模型来源。它 MUST 先按 CLI 自己的优先级确定本次运行实际生效的 provider：绑定了供应商账号时是保留的账号 provider；否则取 Agent 自定义参数里最后一个设置的 `model_provider`，没有时取守护进程专用 Codex 目录配置里的，都没有时为 `openai`；被覆盖的取值 MUST NOT 计入。有效 provider 不是 `openai`，或 CLI 的环境里有缺省 provider 实际使用的 API key 变量，或在专用目录下 `codex login status` 显示已登录，即照常启动；全部明确不成立时 MUST NOT 启动 CLI，运行 MUST 以 `provider_auth` 失败，错误说明绑定供应商账号与在专用目录里登录或配置 provider 两种办法并给出目录路径。登录状态判断不了（超时、命令异常）时 MUST 照常启动并记一条警告。检测到 Codex 而专用目录没有配置时，守护进程 MUST 在启动时打印一行提示，且 MUST NOT 因此把运行时标为不可用。

#### Scenario: 什么都没配置
- **WHEN** Agent `m5-codex` 没有绑定账号、没有 `model_provider` 参数，专用目录没有 `config.toml`，环境里没有 API key 变量，`codex login status` 退出码为 1
- **THEN** 不启动 Codex；运行以 `provider_auth` 失败，错误含 `Bind a provider account` 与专用目录路径；服务端不自动重试

#### Scenario: 绑定了账号
- **WHEN** 同上，但 Agent 绑定了供应商账号
- **THEN** 照常启动，不执行 `codex login status`

#### Scenario: 专用目录选了自定义 provider
- **WHEN** 专用目录的 `config.toml` 顶层 `model_provider = "gateway"`，没有登录
- **THEN** 照常启动

#### Scenario: 参数显式选了 openai
- **WHEN** 专用目录的 `config.toml` 写 `model_provider = "gateway"`，Agent 的自定义参数为 `-c model_provider="openai"`，没有账号、没有 API key 变量，`codex login status` 退出码为 1
- **THEN** 不启动 Codex，运行以 `provider_auth` 失败

#### Scenario: 参数选了自定义 provider
- **WHEN** 专用目录的 `config.toml` 写 `model_provider = "openai"`，Agent 的自定义参数先后为 `-c model_provider="openai"` 与 `-c model_provider="gateway"`，没有登录
- **THEN** 照常启动

#### Scenario: 守护进程已登录
- **WHEN** 没有账号与自定义 provider，`codex login status` 退出码为 0
- **THEN** 照常启动

#### Scenario: 无法判断
- **WHEN** 没有账号与自定义 provider，`codex login status` 10 秒内没有结束
- **THEN** 照常启动，运行事件里有一条说明无法检查登录的警告

#### Scenario: 启动提示
- **WHEN** 守护进程启动，检测到 Codex，专用目录没有登录与 provider 配置，守护进程环境里没有 API key 变量
- **THEN** 打印一行说明 Codex 未为守护进程配置的提示；运行时仍上报为可用

### Requirement: Codex 以完全访问模式运行

适配器 MUST 以 `approvalPolicy: never` 与 `sandbox: danger-full-access` 新建与恢复线程，MUST NOT 依赖 Codex 自带的沙箱（bubblewrap / user namespace），检测阶段 MUST NOT 因沙箱不可用而把 Codex 标为不可用。app-server 在 stderr 打印的沙箱相关日志 MUST NOT 变成运行事件或失败。

#### Scenario: 主机不能创建 user namespace
- **WHEN** 主机不允许创建 user namespace，app-server 启动时在 stderr 打印 bubblewrap 的错误日志，Agent 在运行中执行一条 shell 命令
- **THEN** 命令照常执行；运行没有因这行日志产生错误事件

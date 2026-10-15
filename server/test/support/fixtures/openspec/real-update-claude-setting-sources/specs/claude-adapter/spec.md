## ADDED Requirements

### Requirement: 只加载用户级设置

适配器 MUST 让 Claude Code 只加载用户级设置：每次启动都带 `--setting-sources user`，无论运行描述是否带供应商账号。工作目录（及其仓库根）里的 `.claude/settings.json` 与 `.claude/settings.local.json` MUST NOT 影响托管运行的请求地址、凭据、模型、hooks 与权限；用户的 Claude 设置照常生效；带供应商账号时 `--settings` 覆盖文件照常生效。仓库的说明文件 MUST 照常加载：启动参数 MUST 带 `--add-dir=<工作目录>`（等号写法），CLI 的环境 MUST 设 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`，该值 MUST NOT 被 Agent 的 `env` 改掉。

#### Scenario: 固定参数与环境
- **WHEN** 工作目录为 `/w/T-1` 的运行准备完成
- **THEN** 启动参数在 `--mcp-config <路径>` 之后依次有 `--setting-sources`、`user`、`--add-dir=/w/T-1`；`Launch.env` 含 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` 为 `1`

#### Scenario: Agent 环境改不掉
- **WHEN** Agent 的 `env` 设 `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=0`，运行经 `RunWorker` 启动
- **THEN** CLI 进程环境里该变量为 `1`

#### Scenario: 仓库设置不生效（真实 CLI，不进 CI）
- **WHEN** 未绑定账号，运行的工作目录里有 `.claude/settings.json`，其 `env.ANTHROPIC_BASE_URL` 指向测试里的本机监听端口，另有含标记词指令的 `CLAUDE.md`；用户已在自己的 Claude 配置里登录或配好网关
- **THEN** 运行 `succeeded`；监听端口没有收到连接；结果文本含该标记词

## MODIFIED Requirements

### Requirement: 启动参数与 MCP 注入

适配器 MUST 以无人值守、流式 JSON 输入输出的方式启动 Claude Code：打印模式、stream-json 输入与输出、跳过权限确认、只加载给定的 MCP 配置、只加载用户级设置并把工作目录作为附加目录（见「只加载用户级设置」）；有模型、推理强度、可恢复的会话时分别带上对应参数。MCP 配置 MUST 写在运行私有目录中的 `mcp.json`（0600），包含指向运行描述 `mcp.url` 的 HTTP 服务器 `helmsman` 及运行令牌，以及 Agent 的 `extra_mcp_servers`；`extra_mcp_servers` 里与 `helmsman` 同名的条目 MUST 被丢弃并记一条警告事件。MCP 配置 MUST NOT 写入工作目录。提示词 MUST 作为 stream-json 的第一条用户消息写入 stdin，stdin 保持打开。

#### Scenario: 参数
- **WHEN** Agent 的模型为 `sonnet`、推理强度为 `high`，运行描述带 `resume_session_id` `abc`，工作目录为 `/w/T-1`
- **THEN** 启动参数包含打印模式、`--input-format stream-json`、`--output-format stream-json`、`--verbose`、`--permission-mode bypassPermissions`、`--strict-mcp-config`、`--mcp-config <运行私有目录>/mcp.json`、`--setting-sources user`、`--add-dir=/w/T-1`、`--model sonnet`、`--effort high`、`--resume abc`

#### Scenario: 同名的额外 MCP
- **WHEN** Agent 的 `extra_mcp_servers` 含 `helmsman` 与 `docs` 两项
- **THEN** `mcp.json` 中 `helmsman` 指向运行描述的地址，`docs` 原样保留；运行事件里有一条警告

#### Scenario: 配置文件权限
- **WHEN** 准备完成后检查 `mcp.json`
- **THEN** 它在运行私有目录中、权限为 0600；工作目录里没有任何 MCP 配置文件

### Requirement: 过滤自定义参数

Agent 的 `custom_args` MUST 追加在固定参数之后；与协议冲突的参数（打印模式、输入 / 输出格式、`--verbose`、权限模式与跳过权限、恢复 / 继续会话、会话 ID、MCP 配置、设置来源 `--setting-sources`、模型、推理强度、局部消息流、回放用户消息、不保存会话）MUST 连同其取值一起被剔除，支持 `--flag value` 与 `--flag=value` 两种写法；剔除时 MUST 记一条警告事件列出被剔除的参数名。`--add-dir` MUST 原样保留。

#### Scenario: 剔除
- **WHEN** `custom_args` 为 `["--add-dir", "/data", "--output-format=text", "--resume", "x", "--max-turns", "30"]`
- **THEN** 追加的是 `--add-dir /data --max-turns 30`；警告列出 `--output-format`、`--resume`

#### Scenario: 设置来源
- **WHEN** 未绑定账号，`custom_args` 为 `["--setting-sources", "user,project", "--max-turns", "3"]` 或 `["--setting-sources=project"]`
- **THEN** 启动参数里只有固定的那一个 `--setting-sources user`；追加的自定义参数里没有 `--setting-sources` 及其取值；警告列出 `--setting-sources`

### Requirement: 供应商账号覆盖

运行描述带供应商账号时，适配器 MUST 在运行私有目录写 `claude-settings.json`（0600）并以 `--settings <路径>` 传给 Claude Code，使请求只发往账号的地址、只带账号的密钥、使用账号的模型映射，而用户的 Claude 配置（用户、项目、本地设置）中决定请求地址、凭据与模型的值一律不生效。该文件 MUST：把实测确定的全部供应商相关环境变量设为空串后，再写入账号的地址与模型映射（`default` 同时写入顶层 `model`，没有映射的保持空串）；把 `apiKeyHelper` 设为从进程环境变量 `HELMSMAN_PROVIDER_API_KEY` 读取密钥的命令；MUST NOT 含密钥、MUST NOT 含 `null`。密钥 MUST 只经 CLI 的进程环境变量 `HELMSMAN_PROVIDER_API_KEY` 提供，不写入任何文件或命令行；不能做到时 MUST NOT 以其他方式（含把密钥写进私有文件）启动绑定了账号的运行。此时 `custom_args` 中的 `--settings`（连同取值）MUST 被剔除并记入冲突参数警告（`--setting-sources` 无论是否绑定都按「过滤自定义参数」剔除）。运行描述不带供应商账号时，适配器 MUST NOT 写该文件、加该参数或设该变量，`custom_args` 里的 `--settings` 原样保留。适配器 MUST NOT 修改用户的 Claude 配置，也不改变 Claude 的配置目录。

#### Scenario: 覆盖文件
- **WHEN** 运行描述的账号为地址 `https://api.z.ai/api/anthropic`、密钥 `sk-zai-1`、映射 `default: glm-5.3`、`sonnet: glm-5.3-flash`
- **THEN** 启动参数在 `--mcp-config <路径>` 之后有 `--settings <运行私有目录>/claude-settings.json`；文件权限 0600，其中 `env.ANTHROPIC_BASE_URL` 为该地址、`env.ANTHROPIC_DEFAULT_SONNET_MODEL` 为 `glm-5.3-flash`、`env.ANTHROPIC_AUTH_TOKEN` 与 `env.ANTHROPIC_API_KEY` 为空串、顶层 `model` 为 `glm-5.3`、`apiKeyHelper` 读取 `HELMSMAN_PROVIDER_API_KEY`；文件中没有 `sk-zai-1` 与 `null`；CLI 的环境里 `HELMSMAN_PROVIDER_API_KEY` 为 `sk-zai-1`；启动参数里没有 `sk-zai-1`

#### Scenario: 用户配置不生效
- **WHEN** 用户的 Claude 设置的 `env` 指向另一个地址并带令牌、另有 `apiKeyHelper`，工作目录的 `.claude/settings.json` 也设了地址，运行以账号 `zai` 启动（指向本地假服务）
- **THEN** 假服务收到的请求的 `Authorization` 与 `x-api-key` 都只是账号的密钥；用户与项目配置中的地址都没有收到请求

#### Scenario: 未绑定账号
- **WHEN** 运行描述没有供应商账号
- **THEN** 运行私有目录里没有 `claude-settings.json`，启动参数里没有 `--settings`，环境里没有 `HELMSMAN_PROVIDER_API_KEY`；`custom_args` 里的 `--settings x.json` 原样保留

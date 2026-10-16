# MCP 服务器

## 编辑器

在 Agent 编辑面板的密钥区配置 MCP 服务器。卡片支持 stdio（命令、每行一个参数、环境变量、工作目录）、http 和 sse（地址、请求头）。JSON 模式与卡片使用同一份配置；未修改该区时不提交配置。服务器名仅含字母、数字、下划线和连字符，最多 64 字符，大小写无关唯一；helmsman 保留。

固定环境变量和请求头值只写不读，重新打开时显示「已设置」。未知扩展字段同样隐藏，只显示键名，可删除或用 JSON 替换。常见 tools、超时等类型正确的公开扩展可编辑。JSON 中的「••••••」保留存储值，改名时仍指向原卡片。不要把密钥写在参数或 URL 里。

## 本机变量

用 `${env:NAME}` 引用执行机器的变量，例如 `Bearer ${env:GITHUB_PAT}`。服务端保存引用原文，不取变量值。可以在守护进程的 `daemon.env` 或 Agent 的环境变量里设置变量；Agent 的同名变量优先，空字符串算已设置。`HELMSMAN_*` 不能引用。启动 CLI 前展开引用；缺失时只丢弃该服务器，并在运行事件里记录变量名。四种 CLI 使用同一规则。

## 模板

- GitHub 远程：https://api.githubcopilot.com/mcp/，需要 GITHUB_PAT。
- GitHub 本地容器：docker + ghcr.io/github/github-mcp-server，需要 GITHUB_PAT。
- Playwright：npx @playwright/mcp@latest。
- filesystem：npx -y @modelcontextprotocol/server-filesystem，必须修改目录占位符。
- fetch：uvx mcp-server-fetch。
- Context7：https://mcp.context7.com/mcp。

## 导入

粘贴 Claude/Cursor/Copilot 的 mcpServers JSON、VS Code 的 servers JSON、单条 JSON（另给名字）、Codex config.toml，或 claude/codex mcp add 命令。先预览，再加入卡片，最后保存。`${VAR}` 转为 `${env:VAR}`；默认值被忽略并警告，无法表示的 input 引用留空。同名条目会询问覆盖，也可在加入前改名。

## 个人定义

「个人设置 → 我的 MCP 服务器」管理本人定义（最多 32 条，每条 8 KB）。自己的 Agent 可勾选最多 16 条引用，跨工作区复用。编辑定义从下一次领取运行生效；已领取运行保持原配置。引用中的定义不能删除，先取消 Agent 上的勾选；已归档 Agent 不阻挡删除。定义改名后下一次运行使用新名字，与 Agent 自有配置同名时拒绝改名。其他用户和 API/MCP 令牌不能管理个人定义。

旧数据同名时，自有服务器优先，被覆盖的个人定义在摘要中标为「与自有服务器同名，未生效」，不阻挡运行。支持该协议的守护进程另写一条运行警告；旧守护进程仍正常领取，服务端只记录不含值的结构化日志。

## 本机检查

Agent 详情页的「本机检查」检查命令能否在该 Agent 的 PATH 中找到、变量是否设置及 CLI 是否支持类型；它不执行程序、不联网。结果只回当前页面，不含值。每 Agent 每 10 秒一次，10 秒超时；未绑定、离线及旧守护进程显示原因。Codex 不支持 sse。

含本机引用的运行需支持 MCP 环境引用版本的守护进程，旧版本暂不领取并显示 daemon_outdated；不含引用的配置行为不变。详情页对所属用户与管理员提供打码摘要，其他成员只见名字。

# Helmsman

「人 + Agent」任务管理系统：Elixir / Phoenix LiveView / PostgreSQL。设计文档见 `designs/`。

仓库包含三个并列的 Mix 项目：

- `protocol/`：服务端与守护进程共享的协议库（`:helmsman_protocol`）；
- `server/`：Phoenix 服务端（`:helmsman`）；
- `daemon/`：守护进程（`:helmsman_daemon`）。

## 本地开发

前置条件：已安装 [mise](https://mise.jdx.dev/)（或 asdf）并在 shell 中激活，已安装 Docker（含 Compose）。

```sh
# 1. 按 .tool-versions 安装 Erlang/OTP 与 Elixir
mise install

# 2. 启动 PostgreSQL 16（postgres / postgres @ localhost:5432）
docker compose up -d db

# 3. 三个项目分别获取依赖
(cd protocol && mix deps.get)
(cd server && mix deps.get)
(cd daemon && mix deps.get)

# 4. 服务端建库、迁移并构建前端资源
(cd server && mix setup)

# 5. 质量门禁：告警即失败的编译、未使用依赖检查、格式检查、credo --strict、测试
(cd protocol && mix precommit)
(cd server && mix precommit)
(cd daemon && mix precommit)
```

- `mix precommit` 只检查、不改写文件；格式不对时先运行 `mix format`。
- 类型检查单独运行：在任一项目目录执行 `mix dialyzer`（首次构建 PLT 需要几分钟）。
- 启动服务端：`cd server && mix phx.server`，访问 <http://localhost:4000>。
- 使用其他 PostgreSQL：设置 `DATABASE_URL`（例如 `postgres://user:pass@host/helmsman_test`），服务端的开发与测试配置会改用该地址。
- 注册模式 `HELMSMAN_SIGNUP`：`invite`（缺省）或 `open`；空库时第一个注册的用户不受限制并成为实例管理员。开发环境的邮件（含 magic link）在 <http://localhost:4000/dev/mailbox> 查看。
- 生产环境必须设置 `HELMSMAN_MAILER_ADAPTER`：`smtp`（读 `HELMSMAN_MAILER_SMTP_HOST`、`_PORT`（缺省 587）、`_USERNAME`、`_PASSWORD`、`_TLS`（`always` | `if_available`））或 `log`（邮件只写日志，启动时警告）；发件人 `HELMSMAN_MAILER_FROM`，缺省 `Helmsman <noreply@PHX_HOST>`。

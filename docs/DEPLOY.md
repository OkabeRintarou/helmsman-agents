# 部署 Helmsman 服务器

服务器以容器镜像发布：Elixir release、非 root 用户（uid 10001）、一个 HTTP 端口
（4000）、数据目录卷 `/var/lib/helmsman`，并内置与它同版本的守护进程二进制（供
`/install.sh` 与 `/downloads/daemon/*` 使用）。一台机器上用 `docker compose` 跑起服务器与
PostgreSQL，前面放一个终止 TLS 的反向代理。执行机器上的守护进程安装见
`docs/INSTALL.md`。

## 1. 准备

- Docker 与 Docker Compose v2。
- 一个域名（下文用 `hm.example.com`）和它的 TLS 证书，由反向代理负责（第 3 节）。
  **HTTPS 是前提**：浏览器的会话 Cookie、GitHub 的回调与 Webhook、守护进程的令牌和
  `curl … /install.sh | sh` 都经过这个地址；安装脚本校验的 `.sha256` 与二进制来自同一台
  服务器，只防传输损坏与半截下载，不防中间人或服务器被攻破。
- 能发信的 SMTP（登录链接与邀请走邮件）；没有时可先用 `HELMSMAN_MAILER_ADAPTER=log`，
  邮件（含登录链接）只写进容器日志。

## 2. 用 compose 启动

仓库的 `deploy/` 目录有 `docker-compose.yml`（`app` + `postgres:16`，命名卷 `pgdata` 与
`helmsman-data`，`app` 等 PostgreSQL 健康后再启动）和全部环境变量的示例
`deploy/.env.example`。

```sh
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
# 生成密钥，填进 deploy/.env：
openssl rand -hex 24      # POSTGRES_PASSWORD
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -base64 32   # HELMSMAN_VAULT_KEY（另存一份在服务器之外，丢了就解不开已加密的凭据）
# 再填 HELMSMAN_IMAGE、PHX_HOST 与邮件设置

docker compose -f deploy/docker-compose.yml up -d
curl -fsS http://127.0.0.1:4000/readyz
# {"status":"ok","version":"0.11.0","checks":{"database":"ok","oban":"ok"}}
```

容器每次启动先执行数据库迁移（`bin/start` = `bin/migrate` 再 `bin/server`）：迁移失败
（例如数据库不可达）容器以非零状态退出、不开始服务，按 `restart: unless-stopped` 重试。
多个实例同时启动时用 PostgreSQL advisory lock，只有一个执行迁移。

`HELMSMAN_HTTP_PORT` 决定宿主机上发布的端口（缺省 `4000`）。反向代理在同一台机器上时，
设成 `127.0.0.1:4000` 只在本机发布，外部只能经代理访问。

第一个管理员（实例管理员，可以进 `/admin/github` 与 `/admin/dashboard`）：

```sh
docker compose -f deploy/docker-compose.yml exec app \
  bin/server eval 'Helmsman.Release.bootstrap(email: "you@example.com", workspace: "acme", name: "Acme")'
```

它打印一个 15 分钟有效的登录链接。空实例上第一个注册的用户同样成为实例管理员；
`HELMSMAN_SIGNUP=invite`（缺省）时之后只能凭邀请注册。

### 环境变量

完整说明与示例值在 `deploy/.env.example`。

| 变量 | 说明 |
|---|---|
| `DATABASE_URL` | 必需。compose 由 `POSTGRES_PASSWORD` 拼出，不用另设 |
| `SECRET_KEY_BASE` | 必需。签名 Cookie 与会话，`openssl rand -base64 48` |
| `HELMSMAN_VAULT_KEY` | 必需。32 字节随机数的 base64，加密存储的凭据（GitHub App 私钥、供应商 API key） |
| `PHX_HOST` | 必需。用户与守护进程访问的主机名 |
| `PHX_URL_SCHEME` / `PHX_URL_PORT` | 对外 URL 的协议与端口，缺省 `https` / `443`。`https` 时纯 HTTP 请求被重定向（`localhost` 除外）、带 HSTS、Cookie 带 `Secure` |
| `HELMSMAN_TRUSTED_PROXIES` | 逗号分隔的 IP 或 CIDR。只有来自这些地址的请求才按 `X-Forwarded-For` 取客户端地址、按 `X-Forwarded-Proto` 取协议；不设置时忽略这两个头 |
| `HELMSMAN_MAILER_ADAPTER` | 必需。`smtp` 或 `log`；`smtp` 时 `HELMSMAN_MAILER_SMTP_HOST`（必需）、`_PORT`、`_USERNAME`、`_PASSWORD`、`_TLS` |
| `HELMSMAN_MAILER_FROM` | 系统邮件的发件人，缺省 `Helmsman <noreply@PHX_HOST>` |
| `HELMSMAN_SIGNUP` | `invite`（缺省）或 `open` |
| `HELMSMAN_LOG_FORMAT` / `HELMSMAN_LOG_LEVEL` | `json`（镜像缺省）或 `text`；`debug`、`info`（缺省）、`notice`、`warning`、`error` |
| `HELMSMAN_DATA_DIR` | 数据目录（导出 / 导入文件），镜像里为 `/var/lib/helmsman`（卷 `helmsman-data`） |
| `HELMSMAN_DAEMON_DIST_DIR` | 守护进程二进制目录，镜像里为 `/app/daemon-dist` |
| `HELMSMAN_DAEMON_DOWNLOAD_URL` | 可选。目录里没有某个二进制时，下载端点 302 到 `<此地址>/helmsman-<target>[.sha256]`（例如 GitHub Release 的下载前缀） |
| `POOL_SIZE` / `ECTO_IPV6` | 数据库连接数（缺省 15）；经 IPv6 连接数据库 |
| `GITHUB_APP_*` | 可选，见第 5 节 |

缺少必需变量（或值为空）时容器启动即退出，错误信息里写出变量名。

## 3. 反向代理

代理终止 TLS，把请求转给 `app` 的 4000 端口，需要：

- WebSocket 升级：浏览器的 `/live` 与守护进程的 `/daemon/socket`。
- `X-Forwarded-For` 与 `X-Forwarded-Proto`，并把代理到达容器时的源地址写进
  `HELMSMAN_TRUSTED_PROXIES`。代理在宿主机上、经发布的端口访问时，容器看到的是 Docker
  网桥的网关地址（通常在 `172.16.0.0/12` 里）；代理也在 compose 网络里时是它的容器地址。
  不设置时，登录限流按代理的地址计（所有人共用一个桶），协议按 http 计（`https` 部署会
  反复重定向）。
- `/mcp` 的流式响应不缓冲、长连接不过早超时。

Caddy（自动申请证书，WebSocket 与 `X-Forwarded-*` 默认就有）：

```caddyfile
hm.example.com {
	reverse_proxy 127.0.0.1:4000 {
		flush_interval -1
	}
}
```

nginx：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    http2 on;
    server_name hm.example.com;
    ssl_certificate     /etc/ssl/hm.example.com/fullchain.pem;
    ssl_certificate_key /etc/ssl/hm.example.com/privkey.pem;
    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}

server {
    listen 80;
    server_name hm.example.com;
    return 301 https://$host$request_uri;
}
```

两例的 `deploy/.env`：`PHX_HOST=hm.example.com`、`PHX_URL_SCHEME=https`、
`HELMSMAN_HTTP_PORT=127.0.0.1:4000`、`HELMSMAN_TRUSTED_PROXIES=172.16.0.0/12`。

**内网纯 HTTP**（没有 TLS）：`PHX_URL_SCHEME=http`、`PHX_URL_PORT=<用户访问的端口>`，
Cookie 不带 `Secure`、不重定向。只在可信网络里这样用：令牌与安装脚本都以明文传输。

## 4. 健康检查与监控

- `GET /healthz`：进程存活就 200，不访问数据库；镜像的 `HEALTHCHECK` 用它。
- `GET /readyz`：数据库 2 秒内可查询且后台任务（Oban）在运行时 200 并给出版本，否则
  503 并标出失败的检查项（`checks.database` / `checks.oban` 为 `error`），供负载均衡器使用。
- `/admin/dashboard`：LiveDashboard，只有实例管理员能看（其他用户 404）。除 VM 与数据库
  指标外有 `helmsman.runs.queued.count`、`helmsman.runs.claim.wait_ms`、
  `helmsman.runs.finished.count`（按状态与失败原因）、`helmsman.daemons.online.count`、
  `helmsman.mcp.tool_call.duration`。
- 日志：`docker compose -f deploy/docker-compose.yml logs -f app`。JSON 每行一条，元数据只有
  `request_id`、`workspace_id`、`token_id`、`run_id`、`daemon_id` 等标识；每次 MCP 工具调用
  一行（工具名、身份名、耗时、结果类别），不记录参数与结果内容。令牌、密钥与参数中的
  `password` / `token` / `secret` / `api_key` 等不进日志。

## 5. GitHub App

推荐在浏览器里创建：实例管理员打开 `https://hm.example.com/admin/github`，按页面提交
GitHub App manifest，GitHub 创建 App 后跳回 `/admin/github/callback`，凭据加密存进数据库。
GitHub 的 Webhook 发到 `https://hm.example.com/webhooks/github`，所以这个地址必须能从
公网（GitHub）访问。

也可以手动创建 App，把五个变量都写进 `deploy/.env`（同时设置时优先于浏览器里创建的）：
`GITHUB_APP_ID`、`GITHUB_APP_CLIENT_ID`、`GITHUB_APP_CLIENT_SECRET`、
`GITHUB_WEBHOOK_SECRET`、`GITHUB_APP_PRIVATE_KEY`（一行，换行写成 `\n`）。

## 6. 管理命令

发布包里没有 mix 任务；同样的操作经 `bin/server eval` 执行，不启动 HTTP 服务、不执行
后台任务，可在服务运行时执行，失败时以非零状态退出：

```sh
dc="docker compose -f deploy/docker-compose.yml"

# 迁移（容器启动时已自动执行）；回滚给定版本及其之后的所有迁移（先备份）
$dc exec app bin/migrate
$dc exec app bin/server eval 'Helmsman.Release.rollback(Helmsman.Repo, 20261029090001)'

# 重建全文检索列（全部或一个工作区），同 mix helmsman.reindex
$dc exec app bin/server eval 'Helmsman.Release.reindex()'
$dc exec app bin/server eval 'Helmsman.Release.reindex("acme")'

# 首个管理员 / 工作区，同 mix helmsman.bootstrap
$dc exec app bin/server eval 'Helmsman.Release.bootstrap(email: "you@example.com", workspace: "acme")'

# 工作区导出，同 mix helmsman.export；文件放在数据卷里（HELMSMAN_DATA_DIR）
$dc exec app bin/server eval 'Helmsman.Release.export("acme", "/var/lib/helmsman/acme.json.gz")'

# 导入，同 mix helmsman.import：以 you@example.com（admin 以上）导入到 acme；
# 选项 mode: :merge（缺省）| :replace（要 confirm: "acme"）、dry_run: true、
# rename: %{"旧名" => "新名"}
$dc exec app bin/server eval 'Helmsman.Release.import("/var/lib/helmsman/acme.json.gz", "acme", "you@example.com", dry_run: true)'
$dc exec app bin/server eval 'Helmsman.Release.import("/var/lib/helmsman/acme.json.gz", "acme", "you@example.com", mode: :replace, confirm: "acme")'

# bosun 的导出文件，同 mix helmsman.import_bosun，选项同上
$dc exec app bin/server eval 'Helmsman.Release.import_bosun("/var/lib/helmsman/bosun.json", "acme", "you@example.com")'
```

导出导入的文件要在容器里可读写：放在数据卷 `/var/lib/helmsman` 下，用 `docker compose cp` 拷进拷出。

## 7. 备份与恢复

以 `pg_dump` 为准（数据全在 PostgreSQL 里）：

```sh
$dc exec -T postgres pg_dump -U helmsman -Fc helmsman > helmsman-$(date +%F).dump
```

恢复到一个空库（先停 `app`）：

```sh
$dc stop app
$dc exec -T postgres dropdb -U helmsman helmsman
$dc exec -T postgres createdb -U helmsman helmsman
$dc exec -T postgres pg_restore -U helmsman -d helmsman --no-owner < helmsman-2026-10-14.dump
$dc start app
```

`HELMSMAN_VAULT_KEY` 与备份分开保存：数据库里的凭据用它加密，换了或丢了就无法解开
（需要重新配置 GitHub App 与供应商账号）。卷 `helmsman-data` 只放导出 / 导入的临时文件。

## 8. 升级

镜像标签固定到版本（`HELMSMAN_IMAGE=…:0.11.0`），升级时：

```sh
$dc exec -T postgres pg_dump -U helmsman -Fc helmsman > before-upgrade.dump
# 改 deploy/.env 里的 HELMSMAN_IMAGE 版本
$dc pull app
$dc up -d app
```

新容器启动时自动迁移。迁移失败时容器反复退出：看 `$dc logs app`，修好后重启，或换回
旧版本镜像并用升级前的备份恢复。镜像里的守护进程二进制随之更新；执行机器上重新执行
`curl -fsSL https://hm.example.com/install.sh | sh` 再 `helmsman daemon restart`。

## 9. 守护进程二进制

`GET /install.sh` 与 `GET /downloads/daemon/<target>[.sha256]`（`linux-x64`、`linux-arm64`、
`macos-x64`、`macos-arm64`）不需登录，按 IP 每分钟 60 次。文件来自
`HELMSMAN_DAEMON_DIST_DIR`；没有时重定向到 `HELMSMAN_DAEMON_DOWNLOAD_URL`；二者都没有时
404 并说明。

自己构建镜像（构建上下文是仓库根）：

```sh
docker build -t helmsman .                                    # 不含守护进程二进制
scripts/build-daemon.sh linux-x64 daemon-dist                  # 每个目标在对应平台上构建
docker build --build-arg DAEMON_DIST=daemon-dist -t helmsman . # 含 daemon-dist/helmsman-*
```

`DAEMON_DIST` 必须是构建上下文里的 `daemon-dist/` 或 `dist/`（`.dockerignore` 只放行这两个），
只复制其中的 `helmsman-*` 文件。Elixir / OTP 与 Debian 的版本在 `Dockerfile` 开头，
与 `.tool-versions` 一致。

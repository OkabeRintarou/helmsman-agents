# 安装执行机器上的守护进程

守护进程 `helmsman` 装在运行 Agent CLI 的机器上：连上 Helmsman 服务器、领取运行、
调起本机的 CLI、把过程与结果传回去。它是一个不需要另装 Erlang / Elixir 的单文件，
不需要 root。支持：

- Linux x64、arm64，glibc 2.31 及以上（Debian 11+、Ubuntu 20.04+、RHEL / Rocky 9+）；
- macOS 13 及以上，Intel 与 Apple 芯片。

另外需要 `ps` 与 `kill`（多数系统自带；精简的容器镜像要先装 `procps`）。

服务器的部署见 `docs/DEPLOY.md`。

## 1. 安装

在执行机器上，以运行守护进程的那个系统用户执行：

```sh
curl -fsSL https://hm.example.com/install.sh | sh
```

脚本识别系统与架构，从服务器下载与服务器同版本的二进制和它的 `.sha256`，校验通过后
原子替换安装到 `~/.local/bin/helmsman`（0755）。要装到别处：

```sh
curl -fsSL https://hm.example.com/install.sh | HELMSMAN_BIN_DIR="$HOME/bin" sh
```

安装目录不在 `PATH` 里时脚本会提示。校验和与二进制来自同一台服务器，防的是传输损坏
与半截下载，不防服务器被攻破，所以服务器必须走 HTTPS。

也可以从 GitHub Release 下载 `helmsman-<target>`（`linux-x64`、`linux-arm64`、
`macos-x64`、`macos-arm64`）与同名的 `.sha256`：

```sh
sha256sum -c helmsman-linux-x64.sha256        # macOS: shasum -a 256 -c helmsman-macos-arm64.sha256
install -m 0755 helmsman-linux-x64 ~/.local/bin/helmsman
```

macOS 版没有签名与公证。用 `curl` 下载的文件不带隔离属性，可以直接运行；用浏览器
下载的会被 Gatekeeper 拦下，先去掉隔离属性：

```sh
xattr -d com.apple.quarantine ~/.local/bin/helmsman
```

确认版本（与服务器同一发布）：

```sh
helmsman --version
# helmsman 0.11.0 (protocol 6, linux-x64)
```

第一次运行时二进制把自带的运行时解到 `~/.local/share/.burrito/`（Linux，设置了
`XDG_DATA_HOME` 时在它下面）或 `~/Library/Application Support/.burrito/`（macOS），
之后直接复用；运行更新的版本时自动删除旧版本的运行时。

## 2. 登录

```sh
helmsman login --server https://hm.example.com
```

终端显示设备码与验证地址；在浏览器里打开地址、确认设备码并勾选这台机器服务的工作区。
登录成功后列出工作区。已经登录时加 `--force` 重新登录。终端与日志里不会出现令牌。

`helmsman runtimes` 列出本机检测到的 CLI 与版本、已登录的工作区。

## 3. 后台服务

```sh
helmsman daemon start
```

检查已登录、本机至少有一个可用的 CLI，然后把守护进程装成当前用户的后台服务并启动，
等它连上服务器后打印状态。服务失败时自动重启，登录后自动运行。第一次启动时打印安全
说明：Agent 以守护进程的系统用户身份执行，能读写该用户能访问的一切，建议用专用的、
没有 GitHub 凭据的系统用户运行。

- **Linux**：systemd 用户服务 `~/.config/systemd/user/helmsman-daemon.service`。没有
  用户会话（例如容器里、没有 `systemctl --user`）时命令以 3 退出、不写任何文件——
  这时用 `helmsman daemon start --foreground` 交给自己的进程管理器。
  用户服务在注销后停止；要不登录也运行、开机自动运行，由有 sudo 权限的人执行一次
  （命令不会替你执行）：

  ```sh
  sudo loginctl enable-linger "$USER"
  ```

- **macOS**：launchd 代理 `dev.helmsman.helmsman-daemon`。定义的正本在
  `~/.helmsman/service/`，启用时复制到 `~/Library/LaunchAgents/`，登录后自动运行。

主目录不是缺省的 `~/.helmsman`（设置了 `HELMSMAN_HOME`）时，服务名带上主目录的
哈希，例如 `helmsman-daemon-1a2b3c4d`，同一用户可以为不同主目录各装一个服务。

日常命令：

```sh
helmsman daemon status          # 服务状态、PID、版本、服务器、是否已连接、在跑的运行、磁盘占用
helmsman daemon status --json   # 同上，机器可读
helmsman daemon logs -f -n 200  # 最近 200 行并持续跟随（缺省 100 行）
helmsman daemon restart         # 重写服务定义并重启（升级后用它）
helmsman daemon stop            # 停止并取消自动运行
```

- `status` 的退出码：0 运行且已连接，1 运行但未连接，3 未运行。磁盘占用列出主目录下
  `repos/`、`work/`、`scratch/`、`copilot-home/`、`cursor/` 的大小；CLI 的会话不会自动
  清理（同一任务的后续运行要用它们恢复），需要时人工清理。
- `logs`：Linux 读 journald；macOS 读 `~/.helmsman/logs/daemon.log`（10 MB 轮转，保留
  5 个），launchd 自己的输出在 `~/.helmsman/logs/launchd.log`。
- `stop` 之后重新登录或重启机器都不会再运行，直到再次 `start` 或 `restart`。正在执行
  的运行会被中断，命令先提示数量；服务器按规则重试它们。
- 升级：重新执行安装脚本，然后 `helmsman daemon restart`。安装脚本不会自动重启服务，
  以免打断正在执行的运行。

不用后台服务时，`helmsman daemon start --foreground` 在当前终端运行，Ctrl-C 结束。

## 4. 服务环境与 `daemon.env`

服务管理器给后台服务的环境很少，没有交互 shell 里的变量：

- `PATH` 在执行 `start` / `restart` 时取当前 shell 的值写进服务定义。改了 `PATH`
  （例如新装的 CLI 在别的目录）之后执行一次 `helmsman daemon restart`。
- 其他变量（例如 `CURSOR_API_KEY`、`COPILOT_GITHUB_TOKEN`、供应商的 API 密钥）写进
  `~/.helmsman/daemon.env`：每行一个 `KEY=VALUE`，`#` 开头为注释；值按字面使用，不加
  引号、不做 `$VAR` 展开；只设置服务环境里还没有的变量（服务定义里的 `PATH` 优先），
  `HELMSMAN_` 开头的名字被忽略。文件必须是 0600，否则不读取并在日志里警告。

```sh
umask 077
printf 'CURSOR_API_KEY=%s\n' "$CURSOR_API_KEY" >> ~/.helmsman/daemon.env
chmod 600 ~/.helmsman/daemon.env
helmsman daemon restart
```

`helmsman daemon start` 会列出当前 shell 里有、但服务拿不到的已知凭据变量名
（`CURSOR_API_KEY`、`COPILOT_GITHUB_TOKEN`、`GH_TOKEN`、`OPENAI_API_KEY`、
`ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`），只列名字，不会替你写入任何文件。

## 5. 令牌存放（macOS 钥匙串）

守护进程的 `hmd_` 令牌：

- **macOS** 缺省存进登录钥匙串（通用密码，服务名 `dev.helmsman.daemon`，每一代令牌一项）。
  `~/.helmsman/credentials` 只记服务器、守护进程 ID、签发时间与指向钥匙串项的记录，
  不含令牌。旧版本留下的含令牌的 `credentials` 在新版本第一次启动时自动迁入钥匙串。
- **Linux** 存在 0600 的 `~/.helmsman/credentials` 里（Linux 上设置 `keychain` 是无效
  配置）。

钥匙串在没有图形登录时可能锁着（例如只通过 SSH 使用、无人登录的 Mac），守护进程会以
「the login keychain is locked; log in to the Mac, or set [credentials] store = "file"
in config.toml」退出。这样的机器改用文件存放：

```sh
helmsman logout
cat >> ~/.helmsman/config.toml <<'EOF'
[credentials]
store = "file"
EOF
helmsman login --server https://hm.example.com
```

切换存放方式不会搬动已有的令牌，所以先 `logout` 再 `login`。

钥匙串防的是令牌以明文出现在文件、备份与同步盘里。同一系统用户的进程（包括 Agent）
仍然能用 `security` 读出它：Agent 与守护进程之间本来就没有边界，所以建议用专用的
系统用户运行守护进程。

## 6. 卸载

```sh
helmsman logout     # 先停止并停用后台服务，再吊销这台机器、删除本地凭据与钥匙串项
```

服务器不可达时 `logout` 仍会删除本地凭据，并提示到网页上吊销这台机器。
已安装的服务管理器不可达、服务状态无法确认或停止失败时，`logout` 返回非零并保留凭据；
恢复服务管理器或手动停用服务后再试。然后删除文件：

```sh
# Linux
rm -f ~/.config/systemd/user/helmsman-daemon.service
systemctl --user daemon-reload
rm -rf ~/.local/share/.burrito/helmsman_erts-*
sudo loginctl disable-linger "$USER"   # 只在为它开启过、且不再需要时

# macOS（logout 已删除 ~/Library/LaunchAgents 里的副本）
rm -rf ~/Library/Application\ Support/.burrito/helmsman_erts-*

# 两个平台
rm -rf ~/.helmsman
rm -f ~/.local/bin/helmsman
```

主目录不是缺省值时，把上面的 `~/.helmsman` 与服务名换成实际的主目录和
`helmsman daemon status` 显示的服务名。

## 7. 主目录

`~/.helmsman/`（`HELMSMAN_HOME` 可改）：

| 路径 | 内容 |
|---|---|
| `config.toml` | `server_url`、`max_concurrency`（1–32，缺省 4）、`log_level`、`[credentials] store`、`[codex] home`、本地仓库 |
| `credentials` | 服务器、守护进程 ID、签发时间；文件存放时还有令牌（0600） |
| `credentials.lock` | 跨 CLI 进程的凭据操作锁（0600，不含令牌）；不要单独删除该文件 |
| `status.json` | 运行状态：PID、版本、连接、在跑的运行（0600，不含令牌；`daemon status` 读它） |
| `daemon.env` | 可选，后台服务的环境变量（0600） |
| `logs/` | macOS 后台服务的日志 |
| `service/` | macOS 后台服务定义的正本 |
| `machine_id`、`state/`、`runs/`、`repos/`、`work/`、`scratch/` | 机器 ID、运行记录与工作目录 |

## 8. 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误（含未登录、钥匙串锁定） |
| 2 | 用法错误；以 `mix` 运行时 `daemon start` 不带 `--foreground` |
| 3 | 认证失败；`daemon status` 未运行；当前环境没有可用的服务管理器；`daemon restart` 时未安装 |
| 4 | 与服务器的协议版本不兼容：按提示执行 `curl -fsSL https://hm.example.com/install.sh \| sh` 升级 |
| 5 | 本机没有可用的 Agent CLI |

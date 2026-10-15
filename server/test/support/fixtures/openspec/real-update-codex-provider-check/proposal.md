## Why

M5 验收第 6 步（`add-agents-runs-ui/reviews/m5-acceptance.md`）：托管 Codex Agent `m5-codex` 没有绑定供应商账号，守护进程专用的 `CODEX_HOME`（`~/.helmsman/codex`）里也没有登录或 provider 配置，Codex 于是用缺省的 OpenAI provider 去连 `api.openai.com`（本机不可达），一直 `willRetry`。现有的放弃预算（`add-codex-adapter` 决策 22：连续重试 5 分钟后以 `provider_network` 结束）加上服务端对 `provider_network` 的 3 次重试，会让这张任务被一个**根本没配置**的 Agent 占住半小时以上，验收者只能手动停止。日志里另有「Codex 的 Linux 沙箱需要 bubblewrap 创建 user namespace」，被误读为第二个阻塞原因。

`add-codex-adapter` 决策 3 原本认为「未配置无法离线判断，交给运行以 `provider_auth` 失败」；实测说明在不可达的网络下它不会以 `provider_auth` 失败，而 `codex login status` 能离线判断登录，配置文件与 Agent 参数里的 provider 也能离线读出。

## What Changes

- Codex 适配器在启动 CLI 之前判断「这次运行有没有模型来源」：绑定了供应商账号、专用目录或 Agent 参数选了非 `openai` 的 provider、缺省 provider 能用的 API key 环境变量、或 `codex login status` 显示已登录——任一成立即可；都不成立 → 不启动 CLI，运行以 `provider_auth` 失败（不自动重试），错误说明三种配置方法。判断不了（命令超时、异常）时照常启动。
- 不要求 Codex Agent 必须选供应商账号，也不把运行时标为不可用（同一运行时上的其他 Agent 可能绑定了账号）；守护进程启动时若 Codex 未配置，打印一行本地提示。
- 沙箱：维持 `sandbox: danger-full-access`、`approvalPolicy: never`（14 §9：CLI 本身不提供沙箱，`isolation = none`）；不探测 bubblewrap / user namespace——app-server 启动时那行日志与沙箱模式无关，不影响运行。文档写明。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `codex-adapter`：启动前的模型来源检查；沙箱模式与 bubblewrap 日志（以新增需求表达）。

## Impact

- 守护进程（hm-coder2）：`daemon/lib/helmsman_daemon/adapters/codex.ex`、`codex/config.ex`、`Detector` 的启动提示；测试与一个实测记录。不改协议、服务端与界面。
- designs/：14 §2、§4、§9 同步。

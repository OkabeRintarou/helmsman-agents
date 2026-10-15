# 17 · 规格流程

> 「先写规格、再实现」：一个任务由小队 Leader 找成员起草规格、找成员评审、按评审修订，最终定稿；之后的实现、代码评审、验收沿用现有流程。规格沿用 OpenSpec 的结构，**只存在 Helmsman 里**，能与 `openspec` CLI 的 change 目录互通。规格见 `add-spec-workflow`（界面 `add-spec-workflow-ui`）。

## 1. 用户的决定

| 项 | 决定 |
|---|---|
| 存储 | 只在 Helmsman（版本化文档，网页可看 / 对比 / 评论），不写进代码仓库、不同步 |
| 最终决定 | 按小队或项目配置；缺省「Leader 汇总评审后提出定稿，人批准」，可改为「Leader 自己定稿」 |
| 范围 | 只做规格阶段（起草 → 评审 → 修订 → 定稿 / 批准）；定稿后任务照常指派 / 委派去实现，规格作为后续运行的上下文 |
| 格式 | OpenSpec 的结构（proposal / design / tasks / specs 增量的 Requirement + Scenario）；可导出为 change 目录、从目录导入 |

## 2. 模型

- 每个任务至多一份**规格**（`task_specs`）：`change_id`（kebab-case，工作区内唯一，缺省为任务 ID 小写，导出时的目录名）、状态、最新 / 定稿版本、待批准的提议。可以先建空规格，表示「这个任务要先写规格」。
- **版本**只追加：每版是完整的文件集合——`proposal.md`、`design.md`、`tasks.md`、`specs/<capability>/spec.md`（1–3 段 kebab-case）；单文件 ≤ 256 KB、每版 ≤ 64 个文件且 ≤ 1 MB、每份 ≤ 200 版。提交带 `base_version`（乐观并发），可以只给改动的文件与要删除的路径；同一规格内相同内容只存一份（`task_spec_blobs`）。
- **评审请求** → **评审**（结论 `pass | fail | comment`、摘要、问题）→ **问题**（`P1` 必须改 / `P2` 应该改 / `P3` 建议；位置 = 文件 + 行 + 锚点；问题与建议）→ **讨论**（只追加：作者回复「接受 / 有异议」、评审人撤回、**裁定**「维持 / 驳回」、普通评论）。编号：评审 `R2`、问题 `R2.3`。
- **审计事件**：建立、提交版本、改 `change_id`、请求与结束、提交评审、提议、撤回提议、批准、退回、定稿、放弃、重新打开。版本、评审、讨论、事件只插入；规格与评审请求的可变状态始终等于事件的顺序重放（版本的「曾定稿」也由事件得出），工作区导入据此只比较不可变内容、用重放合并状态。
- 表与约束见 01 §2；加锁时规格行排在任务行之后（01 §4）。可能派发运行的规格写入（请求评审、人提交评审、人定稿 / 批准 / 退回）先猜目标、锁目标、再锁任务行与规格行，在任何写入之前核对，不一致就从保存点重来（同 13 §2 触发目标的加锁）。

## 3. 结构校验

等同 `openspec validate --strict`（1.10 实测）的全部检查，外加 `proposal.md` 有 `## Why` 与 `## What Changes`、`tasks.md` 有勾选项；拿不准的地方取更严的一边，保证「Helmsman 通过 ⇒ openspec 通过」：

- 至少一个 `specs/**/spec.md` 有增量；每个 `spec.md` 至少有一个 `## ADDED|MODIFIED|REMOVED|RENAMED Requirements`；
- ADDED / MODIFIED 的每个 `### Requirement:`：标题到第一个场景之间有正文，正文含 `SHALL` 或 `MUST`（区分大小写，ASCII 单词边界：`系统MUST做` 算，`MUSTER` 不算），至少一个 `#### Scenario:`（`###` 不算）；
- 重名、ADDED / MODIFIED / REMOVED 之间同名、RENAMED 格式；
- 围栏代码块里的标题不算。

草稿可以不通过；**不通过不能定稿**。一致性用例固定在 OpenSpec 1.10 的实测结果上，有 CLI 时可以对照跑。

## 4. 状态与定稿

```
draft ──请求评审──▶ in_review ──请求都结束 / 新版本──▶ draft
draft / in_review ──提出定稿──▶ pending_approval ──人批准──▶ finalized
                                         └──人退回 / 新版本──▶ draft
任意未定稿状态 ──放弃──▶ abandoned；finalized / abandoned ──重新打开──▶ draft
```

- **协调者**：执行方是小队 → 当前 leader（只在以小队身份的 leader 运行里）；执行方是托管 / 外接 Agent → 该 Agent；人（member 以上）随时可以做协调者的事。被委派的成员不是协调者。裁定只给小队 leader 与人。
- **定稿方式**：执行方小队设置了 `spec_finalize` 用小队的，否则用项目的（缺省 `approval`）。`leader` 只对小队生效，设为 `leader` 只限 admin（否则 leader 的所属用户能绕过 admin 在项目上要求的人工批准）。
- **门槛**：最新版本、校验通过、没有待回复 / 有异议的 P1 / P2、最新版本没有待完成的评审请求。
- `approval`：协调者 `finalize_spec`（附评审汇总）→ `pending_approval` → 人批准或退回；`leader`：小队 leader 直接定稿。人随时可以直接定稿；Agent 身份永远不能批准。
- 规格状态**不**卡任务迁移：「先规格后实现」由 leader 提示词、工作流文档与人的批准保证。

## 5. 编排

| 动作 | 怎么做 |
|---|---|
| 起草 / 修订 | leader `delegate(task, to, instructions, spec: "draft" \| "revise")`：同 16 §1.2 的委派，提示词按角色说明做法 |
| 请评审 | leader `delegate(…, spec: "review")`：为该成员建评审请求并排运行；对人类成员只建请求。人（网页 / REST）或外接 Agent 协调者 `request_spec_review`：托管 Agent 得到新发起的 `spec_review` 运行（`reply` lane） |
| 唤醒 leader | 委派的运行结束 → `delegate_done`（16 §1.2）；人交了运行请求的评审 → `spec_reviewed`；人批准 / 退回 / 直接定稿（可选不唤醒）→ `spec_decided`。后两者继承「任务 × 执行方」的指派授权（同打回，13 §2.1） |
| 结算 | 一个评审请求只属于一条触发（已有待完成的请求时委派评审返回 `review_pending`）；生命周期 = 所在运行 + 自动重试的接续，与 `delegate_done` 相同：不再重试时（含重试没排上队）没交评审的请求记为 `lapsed`。运行终态事务只插入 Job，结算在独立事务里按任务写的锁顺序进行，`delegate_done` 唤醒之前先结算 |

## 6. 运行上下文

- 任务有规格时，每次运行的提示词带一行规格状态（≤ 512 字节）并指向 `get_spec`；已定稿时写明按定稿版本实现；任务没有规格而 Epic 有已定稿的规格时指向 Epic 的规格。规格正文不进提示词（13 §6）。
- leader 运行在小队一节之后另有 `## Specs` 一节（≤ 2 KB）：流程、定稿方式、「定稿前不安排实现」。
- `helmsman://workflow` 有 Specs 一节。

## 7. 互通与导出

- **单份规格**：导出某一版为 `tar.gz` / `zip`（`<change_id>/…` + `.openspec.yaml`，可带 `reviews/spec-review-<n>.md`），解压到仓库的 `openspec/changes/` 即可 `openspec validate --strict`；导入同样结构的压缩包作为新版本（全部在内存里处理，拒绝链接、绝对路径与 `..`）。
- **工作区导出**（11 §1.1）：格式 v2 含规格、版本原文、评审、问题、讨论与审计事件；导入接受 v1 / v2，规格按自己的序列快进合并。

## 8. 接口

- MCP（08 §3）：`get_spec` `diff_spec` `list_spec_reviews`；`submit_spec_version` `submit_spec_review` `reply_spec_issue` `rule_spec_issue` `finalize_spec` `update_spec` `cancel_spec_review`；`request_spec_review`（非运行令牌）；`delegate` 的 `spec`；`get_task` 带规格摘要。
- REST（11 §2）：`/tasks/:id/spec` 下同名端点，另有人专用的 `finalize` / `reject`、`export` / `import`、`/me/specs`。
- 界面（09）：任务页的规格卡片、规格页 `/w/:slug/t/:ident/spec`（渲染、版本对比、评审与讨论、批准 / 退回、导出导入）、仪表盘的待处理、项目与小队的定稿方式设置。

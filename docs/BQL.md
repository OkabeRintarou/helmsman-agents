# BQL 任务查询

网页入口 `/w/:slug/query`（界面变更启用后）；MCP 使用
`query_tasks(bql: "status = new")`，速查资源 `helmsman://bql`。
必须恰好给 `bql` 或 `filter_id` 之一；结果含任务摘要、`total`、`order`。
分页 `limit` 缺省 50，范围 1–200；`offset` 范围 0–10000。
查询只读取当前工作区；5 秒语句超时会提示缩小范围。

## 语法

空查询匹配全部；`NOT` > `AND` > `OR`，括号改变优先级。
关键字、字段名不分大小写。值可裸写（含中文），有空白、括号、逗号、
引号、运算符字符或关键字时必须用双引号。引号内 `\"` 转义引号，
`\\` 转义反斜杠，其他反斜杠原样保留。
运算为 `= != ~ !~ > >= < <=`、`IN (...)`、`NOT IN (...)`、
`IS EMPTY`、`IS NOT EMPTY`；`NULL` 等同 `EMPTY`。
`~` 是不分大小写的字面子串，`text` / `feedback` 使用全文检索。
上限：2000 Unicode 码点、64 个条件、32 层括号/NOT、IN 列表 100 个值、
5 个排序字段。错误带消息与位置（Unicode 码点，从 1 起；结尾错误为长度 + 1，
未结束字符串指向起始引号）。

## 字段

E = `= != IN NOT IN`；S = `~ !~`；C = `> >= < <=`；Z = `IS [NOT] EMPTY`。

| 字段 | 别名 | 运算 | 值与语义 |
|---|---|---|---|
| project | key | E | 项目 Key |
| id | | E, S | 等于/IN 要求 KEY-N，S 为子串 |
| status | | E | new、in_progress、done、verified、rejected、cancelled；兼容 "in progress"、in-progress、canceled |
| priority | | E, C | low < medium < high |
| labels | label | E, S, Z | 存在匹配标签 |
| created_by | creator, reporter, requester | E, S | 提出方身份名，E 支持 currentUser() |
| assignee | | E, S, Z | 执行方身份名，E 支持 currentUser() |
| kind | type | E | task、epic |
| epic | parent | E, Z | Epic 的 KEY-N |
| blocked | | = != | true/false、yes/no，未满足的依赖 |
| depends_on | | E, Z | 被依赖的任务 KEY-N |
| blocks | | E, Z | 依赖本任务的 KEY-N |
| replaces | | E, Z | 被本任务替代的 KEY-N |
| replaced_by | | E, Z | 替代本任务的 KEY-N |
| title | | = !=, S | 标题全等或子串 |
| description | | S, Z | 描述子串，空串为空 |
| text | | S | 任务与有效 Feedback 的全文 |
| feedback | | S, Z | 有效 Feedback 的全文 |
| created | | C | UTC 创建日期 |
| updated | | C | UTC 更新日期 |
| question | open_question | = != | true/false、yes/no，当前未回答提问 |
| feedback_count | | = !=, C | 有效 Feedback 非负整数计数 |
| assignee_kind | | E | human、agent、squad、system |
| created_by_kind | | E | human、agent、squad、system |
| owner | | E | 用户 human 身份名；执行方是他本人或他的 Agent；支持 currentUser() |
| run | | E, Z | 最近运行（任意 Agent/lane）：deferred、queued、claimed、running、cancelling、succeeded、failed、cancelled |
| pr | | E, Z | 当前最近 PR：draft、open、merged、closed |
| ci | | E, Z | 当前 PR 检查：pending、success、failure；none 为空 |
| merge | | E, Z | 当前 PR 合并：waiting、stale、merged、blocked、failed；none 为空 |

`squad` 支持 E，按小队名匹配小队身份、当前 leader 和成员。
成员和 leader 变更在下一次查询生效；`assignee_kind = squad` 只匹配小队身份本身。
名字和枚举不分大小写；不存在的名字只匹配不到，非法 ID 和枚举报错。
多值/关联字段的正向运算是存在匹配，否定是不存在匹配；可空字段的否定包含
空值。`!~` 等于 `NOT (~)`；任意条件及其 NOT 互补。

## 日期与身份

UTC 日期支持 `YYYY-MM-DD`（零点）、`YYYY-MM-DDTHH:MM[:SS]`（t 可小写）、
`now`、`-Nm` / `-Nh` / `-Nd` / `-Nw`（N 为 1–100000）。同一查询共用同一现在。
`currentUser()` 只用于 assignee、created_by、owner 的 E 运算，保存时保留符号，
执行时解析：网页为本人的 human，外接 Agent 会话为当前身份，运行令牌为本次运行
托管 Agent；owner 取对应用户。无缺省 Agent 且未 identify 的 MCP 会话必须先
identify，普通查询照常执行；不会回退 human 或比较空值。

## 排序与示例

`ORDER BY field [ASC|DESC]`，逗号列多个字段；缺省 ASC，两种方向空值均最后。
可排序：id（项目/序号）、project、status（状态机顺序）、priority（自然顺序）、
kind、title、assignee、created_by、created、updated、feedback_count、question、
run、pr（枚举顺序）；名字不分大小写。并列回落 updated DESC、内部 ID DESC。
没写排序且有 NOT 之外的 text ~ / feedback ~，按各条件相关度之和降序；否则 updated DESC。

```bql
project = BOS AND status IN (new, "in progress") ORDER BY priority DESC
```
```bql
assignee = currentUser() AND NOT blocked = true
```
```bql
text ~ "创建任务" AND updated >= -7d
```

## 保存的筛选器与兼容

`list_filters` / `save_filter` / `delete_filter`：名字 1–80 码点，同一用户/工作区
不分大小写唯一，最多 100 个；新建必须给名字与 BQL，shared 缺省 false。
带 filter_id 只改给出的字段，空修改不改版本；lock_version 拒绝过期更新，
不带版本后写覆盖。member 以上可写；viewer 和运行令牌只读。私有仅所有者可见；
共享全工作区可见，所有者/admin 可改删，只有所有者可改共享状态。
离开工作区同事务删除私有，共享保留并标记所有者已离开；提交后通知。

与 bosun 的差别：只算有效 Feedback；提问只由 answer 关闭；全文使用 PostgreSQL
与 Search 同一分词，相关度 ts_rank_cd（非 BM25）；分页缺省/最多 50/200
（bosun 为 100/500）；错误含位置；新增身份种类、owner、currentUser()、run、pr、
ci、merge、squad。本实现独立编写，不包含 multica 源码或素材。

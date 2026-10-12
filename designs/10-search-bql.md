# 10 · 全文检索与 BQL

> 对应 bosun 的 08、09。bosun 用 bitcask（C++ NIF，BM25 + jieba）做外挂索引，BQL 把全部任务取到内存里逐条求值。
> Helmsman 两者都下沉到 PostgreSQL：检索列和业务数据在同一事务里写入，BQL 编译成一条 SQL。

## 1. 全文检索

### 1.1 中文怎么分词

PostgreSQL 内置的文本检索不会切中文。可选方案：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **Elixir 侧分词，直接写 tsvector**（选用） | 纯 Elixir、不装扩展、托管 PG（RDS、Supabase…）都能用 | 中文用二元组，相关度不如词典分词 |
| `zhparser` / `pg_jieba` 扩展 | 词典分词，质量好 | 要自己编 PG 扩展，托管 PG 大多不支持 |
| `jieba` hex 包（Rustler NIF） | 词典分词，在 Elixir 侧 | 下载量很小，要 Rust 工具链或预编译 |
| `pg_trgm` 三元组 | 内置 | 对中文（一两个字的词）效果差，只用于 ID / 标题子串 |

`Helmsman.Search.Tokenizer` 是一个行为（behaviour），缺省实现 `Bigram`：

- 拉丁字母和数字：由字母、数字、组合符组成的词，内部可含连接符 `-` `_` `/`（首尾的去掉）；先 NFKC（全角转半角）再转小写，再额外产出按连接符拆开的片段（`feature-search` → `feature-search` `feature` `search`；`BOS-12` → `bos-12` `bos` `12`），片段与原词占同一个位置；超过 64 个字符的词或片段不输出；
- 连续的中日韩字符（Han、平假名、片假名、Hangul）：输出相邻二元组（`任务管理` → `任务` `务管` `管理`），位置连续；孤立的单个字输出它本身；
- 停用词只去掉极少数（`the` `a`，以及单独出现的 `的` `了`），避免误伤；停用词仍占一个位置。

行为有两个回调：`tokens/1`（词元、位置、原文中的字节偏移，建索引与片段用）与 `query/1`（查询的组：词、前缀、短语，见 §1.3）。以后要换 jieba，实现同一个行为即可，再跑一次 `mix helmsman.reindex` 重算所有检索列（`add-fulltext-search` 决策 3）。

### 1.2 检索列

| 表 | 内容与权重 |
|---|---|
| `tasks.search` | ident、标签 → A；标题 → A；描述 → B |
| `feedback.search` | 内容 → C；作废后置空 |

写法：Elixir 产出 `{词元, 位置, 权重}`，以 `%Postgrex.Lexeme{}` 列表经二进制协议直接写入（自定义 Ecto 类型 `Search.TsVector`，不拼字面量、不需要转义；字段 `load_in_query: false`，普通读取不取它），两列各有 GIN 索引。
不用 `array_to_tsvector`——它不带位置，中文二元组的相邻匹配（`<->`）就失效了；也不用 `to_tsvector`，免得 PG 再按自己的规则切一遍。
在建单、编辑（标题 / 描述 / 标签有变化时）、写 Feedback 的同一事务里更新，**没有异步索引**；只在部署检索之后与更换分词器之后运行一次重建（`mix helmsman.reindex`：逐行一条语句、带「内容未变」条件地写回，不阻塞业务写入、不覆盖并发的新值，`add-fulltext-search` 决策 9）。

位置的规则：

- 各字段按 ident → 标签 → 标题 → 描述的顺序**接着编号**（从 1 开始，空字段不占位置），字段之间空出 10 个位置，避免短语跨字段匹配（标题末尾 + 描述开头）。
- PostgreSQL 的位置上限是 16383，超过的会被压到 16383；同一词元最多保留 256 个位置（实测 PG 16 都是静默处理）。64 KB 的中文描述能产生三万多个二元组，所以超过上限的部分**只保留词元、不写位置**（不压到 16383，免得一堆词挤在同一位置造成误匹配）：
  单词检索照样命中，只是描述末尾的长短语匹配可能漏掉。这是有意接受的取舍，比拆成多个文档简单。
- 同理，tsvector 总大小上限 1 MB，64 KB 的正文远远到不了。

### 1.3 查询

- 查询串（去掉首尾空白后最多 200 个字符，空白返回空结果）用同一个 Tokenizer 的 `query/1` 切成组，拼成 tsquery 字面量（转义单引号与反斜杠，以 `$1::text::tsquery` 传入）：组与组之间 `&`；同一段中文的二元组之间用 `<->`（相邻），整段必须连续出现；
  最后一个拉丁词加前缀匹配 `word:*`，方便边输边搜；只有一个中文字时用 `字:*`（命中以它开头的二元组）；最多 16 组。
- 匹配：任务自己的 `search` 命中，**或者**它的某条有效 Feedback 命中；一条 SQL 把两者全外连接，分数取 `ts_rank_cd` 的较大者（同分按更新时间），命中来自 Feedback 时带上 `feedback: %{id, author, kind, snippet}`；之后各一条查询加载摘要与 Feedback，查询次数与命中数无关。
- 片段**在 Elixir 里生成**，不用 `ts_headline`：后者会按 PG 自己的规则重新切词，对中文二元组不起作用，输出的 HTML 也不能直接信任。
  做法：用同一个 Tokenizer 带上字符偏移切原文，找到第一个命中词元，截取前后各约 40 个字素，压缩空白，两端被截时加 `…`。领域层返回分段 `[%{text, hit}]`，由渲染函数输出：`Snippet.to_html/1` **先 HTML 转义**再用 `<mark>` 包住命中部分（网页），`to_text/1` 用 `**` 标出（MCP）（`add-fulltext-search` 决策 7）。任务结果的片段取自描述，命中只在 ID / 标签 / 标题时没有片段。
- ID 直达：查询串本身是 `BOS-12` 的形式时，该任务排第一。
- 永远带 `workspace_id` 条件；可选 `project_key`。

接入点：顶栏全局搜索、MCP `search_tasks`、REST `/search`（以上用 `Search.search/3`，按相关度）；列表页的搜索框与 MCP `list_tasks` 的 `query`（`Tasks.list/3` 的 `:q`：只筛选，排序与分页仍按更新时间）；BQL 的 `text ~` / `feedback ~`（复用 `Search.Query` 与 `Search.task_matches/2`）。

## 2. BQL

### 2.1 语法与字段

与 bosun 的 BQL **语法和字段兼容**（已有的筛选器、Agent 提示词都能直接用）。语义上有两处有意的差别：`feedback_count` 只算有效记录、`question` 只有 `answer` 能关掉（06 §2–3）。语法：

```
query  := [expr] [ORDER BY field [ASC|DESC] {, field [ASC|DESC]}]
expr   := term {OR term};  term := factor {AND factor}
factor := NOT factor | '(' expr ')' | cond
cond   := field op value | field [NOT] IN '(' values ')' | field IS [NOT] (EMPTY | NULL)
op     := = | != | ~ | !~ | > | >= | < | <=
```

字段沿用 bosun：`project` `id` `status` `priority` `labels` `created_by` `assignee` `kind` `epic` `blocked`
`depends_on` `blocks` `replaces` `replaced_by` `title` `description` `text` `feedback` `created` `updated`
`question` `feedback_count`（别名、可用运算、值的写法见 bosun 的 `docs/BQL.md`，实现 BQL 时（`add-bql-filters`）搬过来改写成 `docs/BQL.md`）。

新增：

| 字段 | 运算 | 说明 |
|---|---|---|
| `assignee_kind` `created_by_kind` | `= !=` | `human` / `agent` |
| `owner` | `= != IN` | Agent 的所属用户（`owner = alice` 找 alice 本人和她所有 Agent 的任务） |
| 值 `currentUser()` | 用于 `assignee` `created_by` `owner` | 当前用户本人的 human actor；对 `owner` 是当前用户 |
| `run` | `= != IN` | 最近一次运行的状态：`deferred` `queued` `claimed` `running` `cancelling` `succeeded` `failed` `cancelled`；`run IS EMPTY` = 从没跑过 |
| `pr` | `= != IN IS EMPTY` | PR 状态：`draft` `open` `merged` `closed` |
| `ci` | `= !=` | PR 的检查状态：`pending` `success` `failure` |
| `merge` | `= !=` | 合并进度：`waiting` `stale` `merged` `blocked` `failed` |
| `squad` | `= != IN` | 执行方是这个小队，或执行方是它的成员 |

### 2.2 实现

```
"status = NEW AND text ~ 搜索"
   │ Helmsman.BQL.Parser（NimbleParsec）
   ▼
AST  {:and, [{:cond, :status, :eq, [:new]}, {:cond, :text, :match, "搜索"}]}
   │ Helmsman.BQL.Normalizer：别名 → 规范字段；值按字段校验、归一（大小写、相对时间 → 绝对时间、ident 格式）
   ▼
   │ Helmsman.BQL.Compiler：AST → Ecto.Query.dynamic/2
   ▼
from t in Task, where: t.workspace_id == ^ws and ^dynamic, order_by: ..., limit: ..., offset: ...
```

| 条件 | 编译成 |
|---|---|
| 标量字段 | 列比较；`priority` 的 `>` 用 `CASE` 映射成整数比较 |
| `labels = x` | `labels @> ARRAY[^x]`（走 GIN）；`~` 用 `EXISTS (SELECT 1 FROM unnest(labels) l WHERE l ILIKE …)` |
| `created_by` / `assignee` | 子查询 `actors` 比较名字（不用 join，避免多行） |
| `blocked` | 07 §3 的 `EXISTS` 子查询 |
| `depends_on` / `blocks` / `replaces` / `replaced_by` | `EXISTS` 查 `task_links` |
| `text ~` | `t.search @@ q OR EXISTS (feedback f WHERE f.task_id = t.id AND f.search @@ q)` |
| `title ~` / `id ~` | `ILIKE`，`pg_trgm` GIN 索引加速 |
| `question` / `feedback_count` | 直接用冗余列 |
| `run` | `LATERAL` 取该任务最近一条运行的状态 |
| `pr` / `ci` / `merge` | `EXISTS` 查 `task_pull_requests` |

**否定与空值**的规则（直接决定结果对不对，与 bosun 的语义逐条对齐）：

- 多值字段和关联字段（`labels`、`depends_on` 等）：`=` / `IN` 是「存在一个匹配」，`!=` / `NOT IN` 是「**不存在**匹配」，编译成 `NOT (…)` / `NOT EXISTS`，而不是「存在一个不相等的」。
- 可空字段（`assignee`、`epic`）：`!=` 用 `IS DISTINCT FROM`，`NOT IN` 用 `x IS NULL OR x <> ALL(…)`。所以 `assignee != alice` 包括还没人领的任务（与 bosun 一致）。
- 每个条件都编译成**不会为 NULL** 的布尔表达式（必要时 `COALESCE(…, false)`），`NOT expr` 才符合直觉。
- 测试：把 bosun 的 `bosun_bql_tests.erl` 用例搬过来作为兼容性用例，同一份数据在两边结果一致。

- 缺省排序：有 `text` / `feedback` 条件时按相关度，否则 `updated DESC`。
- 所有值都通过 Ecto 参数传入，字段名走白名单，不存在 SQL 注入面。
- BQL 查询在 `SET LOCAL statement_timeout = '5s'` 的事务里执行，`limit` 上限 200。
- 解析错误 `{:invalid_bql, %{message, position}}`：界面把出错位置标红，MCP 文本给出位置和可用字段。
- 测试：解析器用 StreamData 生成随机 AST → 打印成字符串 → 再解析，断言往返相等；编译结果用固定数据集逐字段对照预期。

## 3. 保存的筛选器

- `saved_filters`：`name`、`bql`、`visibility`（`private` 只有自己看到；`workspace` 全员可见，作者或 admin 可改 / 删）。
- 保存前先解析一次，非法 BQL 不能保存。
- 侧栏列出「我的」和「共享」两组；`/w/:slug/query?filter=<id>` 打开。
- MCP：`list_filters` `save_filter(name, bql, filter_id?, shared?)`（带 `filter_id` 是更新）`delete_filter(filter_id)`；`query_tasks` 也接受 `filter_id`。

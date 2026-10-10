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

- 拉丁字母和数字：按 Unicode 词边界切，转小写，再额外产出 `-`、`_`、`/` 拆开后的片段（`feature-search` → `feature-search` `feature` `search`），片段与原词占同一个位置；
- 连续的中日韩字符：输出相邻二元组（`任务管理` → `任务` `务管` `管理`），位置连续；孤立的单个字输出它本身；
- 停用词只去掉极少数（`的` `了` `the` `a`），避免误伤。

以后要换 jieba，实现同一个行为即可，再跑一次 `mix helmsman.reindex` 重算所有检索列。

### 1.2 检索列

| 表 | 内容与权重 |
|---|---|
| `tasks.search` | ident、标签 → A；标题 → A；描述 → B |
| `feedback.search` | 内容 → C；作废后置空 |

写法：Elixir 产出 `{词元, 位置, 权重}`，拼成 tsvector 字面量（`'任务':1A '务管':2A …`，转义单引号和反斜杠）后以 `$1::tsvector` 写入。
不用 `array_to_tsvector`——它不带位置，中文二元组的相邻匹配（`<->`）就失效了；也不用 `to_tsvector`，免得 PG 再按自己的规则切一遍。
在建单、编辑、写 Feedback 的同一事务里更新，**没有异步索引，也不需要重建**。

位置的规则：

- 各字段按 ident → 标签 → 标题 → 描述的顺序**接着编号**，字段之间空出 10 个位置，避免短语跨字段匹配（标题末尾 + 描述开头）。
- PostgreSQL 的位置上限是 16383，超过的会被压到 16383。64 KB 的中文描述能产生三万多个二元组，所以超过上限的部分**只保留词元、不写位置**：
  单词检索照样命中，只是描述末尾的长短语匹配可能漏掉。这是有意接受的取舍，比拆成多个文档简单。
- 同理，tsvector 总大小上限 1 MB，64 KB 的正文远远到不了。

### 1.3 查询

- 查询串用同一个 Tokenizer 切开，拼成 tsquery 字面量（`$1::tsquery`）：词与词之间 `&`；同一段中文的二元组之间用 `<->`（相邻），整段必须连续出现；
  最后一个拉丁词加前缀匹配 `word:*`，方便边输边搜；只有一个中文字时用 `字:*`（命中以它开头的二元组）。
- 匹配：任务自己的 `search` 命中，**或者**它的某条有效 Feedback 命中；分数取 `ts_rank_cd` 的最大值，命中来自 Feedback 时带上 `feedback: %{id, author, kind, snippet}`。
- 片段**在 Elixir 里生成**，不用 `ts_headline`：后者会按 PG 自己的规则重新切词，对中文二元组不起作用，输出的 HTML 也不能直接信任。
  做法：用同一个 Tokenizer 带上字符偏移切原文，找到命中词元的位置，截取前后各约 40 字，**先 HTML 转义**再用 `<mark>` 包住命中部分。
- ID 直达：查询串本身是 `BOS-12` 的形式时，该任务排第一。
- 永远带 `workspace_id` 条件；可选 `project_key`。

接入点：顶栏全局搜索、列表页的搜索框、MCP `search_tasks`、REST `/search`、BQL 的 `text ~` / `feedback ~`。

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
`question` `feedback_count`（别名、可用运算、值的写法见 bosun 的 `docs/BQL.md`，M6 时搬过来改写成 `docs/BQL.md`）。

新增：

| 字段 | 运算 | 说明 |
|---|---|---|
| `assignee_kind` `created_by_kind` | `= !=` | `human` / `agent` |
| `owner` | `= != IN` | Agent 的所属用户（`owner = alice` 找 alice 本人和她所有 Agent 的任务） |
| 值 `currentUser()` | 用于 `assignee` `created_by` `owner` | 当前用户本人的 human actor；对 `owner` 是当前用户 |
| `run` | `= != IN` | 最近一次运行的状态：`queued` `running` `succeeded` `failed` `cancelled`；`run IS EMPTY` = 从没跑过 |
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

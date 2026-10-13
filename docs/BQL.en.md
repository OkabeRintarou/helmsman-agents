# BQL task queries

Use `query_tasks(bql: "status = new")` in MCP. Read this guide as the
`helmsman://bql` resource. The query page is `/w/:slug/query` when enabled.
`query_tasks` accepts exactly one of `bql` or `filter_id`; pagination uses
`limit` (default 50, 1–200) and `offset` (0–10000). Results contain task
summaries, `total`, and `order`. All queries are restricted to your workspace.
A five-second statement timeout returns guidance to narrow your query.

## Grammar

An empty query matches everything. Conditions use `AND`, `OR`, `NOT` and
parentheses; `NOT` binds more tightly than `AND`, which binds more tightly
than `OR`. Keywords and field names are case insensitive. Values may be
bare words, including Chinese, or double-quoted strings. Quote values
containing whitespace, parentheses, commas, quotes, operator characters or
keywords. In quoted strings `\"` represents a quote and `\\` a backslash;
other backslashes stay literal. Operators are `= != ~ !~ > >= < <=`,
`IN (...)`, `NOT IN (...)`, `IS EMPTY`, `IS NOT EMPTY`. `NULL` is an alias
for `EMPTY`. `~` is a literal, case insensitive substring search except
for `text` and `feedback`, which use full-text search.

Maximums: 2000 Unicode codepoints, 64 conditions, 32 nested parentheses or
`NOT` operators, 100 values per `IN` list, five ordering fields. Errors
include a message and one-based Unicode codepoint position. An unexpected
end points one past the query; an unclosed string points at its opening quote.

## Fields

In the table, E means `= != IN NOT IN`, S means `~ !~`, C means `> >= < <=`,
and Z means `IS EMPTY IS NOT EMPTY` (including `NULL` aliases).

| Field | Aliases | Operators | Values / meaning |
|---|---|---|---|
| project | key | E | Project key, case insensitive |
| id | | E, S | `KEY-N` for equality; literal substring for S |
| status | | E | new, in_progress, done, verified, rejected, cancelled; also "in progress", in-progress, canceled |
| priority | | E, C | low < medium < high |
| labels | label | E, S, Z | Has any matching label, case insensitive |
| created_by | creator, reporter, requester | E, S | Creator identity name; E accepts currentUser() |
| assignee | | E, S, Z | Assignee identity name; E accepts currentUser() |
| kind | type | E | task, epic |
| epic | parent | E, Z | Epic's `KEY-N` |
| blocked | | = != | true/false, yes/no; unsatisfied dependencies |
| depends_on | | E, Z | Outgoing dependency task ID |
| blocks | | E, Z | Incoming dependency task ID |
| replaces | | E, Z | Task ID this task replaces |
| replaced_by | | E, Z | Task ID replacing this task |
| title | | = !=, S | Case insensitive title equality or substring |
| description | | S, Z | Description substring; empty string is empty |
| text | | S | Full-text search over task fields and active feedback |
| feedback | | S, Z | Full-text search over active feedback only |
| created | | C | UTC creation date/time |
| updated | | C | UTC last update date/time |
| question | open_question | = != | true/false, yes/no; unanswered question |
| feedback_count | | = !=, C | Nonnegative count of active feedback |
| assignee_kind | | E | human, agent, squad, system |
| created_by_kind | | E | human, agent, squad, system |
| owner | | E | Human identity name; assignee is that human or an agent they own; currentUser() supported |
| run | | E, Z | Latest run across agents and lanes: deferred, queued, claimed, running, cancelling, succeeded, failed, cancelled |
| pr | | E, Z | Latest PR: draft, open, merged, closed |
| ci | | E, Z | Latest PR checks: pending, success, failure; none is empty |
| merge | | E, Z | Latest PR merge progress: waiting, stale, merged, blocked, failed; none is empty |

`squad` supports E and matches a squad identity, its current leader and
members by squad name. Membership and leader changes take effect on the
next query. `assignee_kind = squad` matches only the squad identity itself.

Names and enums compare case insensitively. Unknown names match nothing;
malformed task IDs and unknown enum values are errors. `labels = backend`
means a matching label exists; `labels != backend` means no matching label
exists. This existence rule also applies to links and squads. For nullable
fields, negative conditions include missing values. `!~` means `NOT (~)`;
any condition and its `NOT` are complementary even when a value is missing.

## Dates and identity

Dates are UTC: `YYYY-MM-DD` means midnight; `YYYY-MM-DDTHH:MM` and
`YYYY-MM-DDTHH:MM:SS` accept lower-case `t` too. `now` and `-Nm`, `-Nh`,
`-Nd`, `-Nw` use the same instant throughout one query (N is 1–100000).

`currentUser()` may be used only in equality/IN conditions on `assignee`,
`created_by` and `owner`. It remains symbolic when saved. In the browser it
means your human identity; in an external agent's MCP session it means the
session identity; with a run token it means the managed agent executing the
run. `owner` resolves that identity to its user. An MCP session without a
default agent or identified identity must call `identify` first; ordinary
queries still work. The error is: `currentUser() needs an identity; call
identify first.` No fallback identity is used.

## Ordering

Append `ORDER BY field [ASC|DESC]` and optional comma-separated fields.
Default direction is ASC; missing values come last in both directions.
Sortable fields: id (project and sequence), project, status (state machine
order), priority (natural order), kind, title, assignee, created_by, created,
updated, feedback_count, question, run, pr. Identity/title sorting is case
insensitive; run and PR use their listed enum order. Ties fall back to
updated descending and internal ID descending, so pages remain stable.
Without ORDER BY, positive `text ~`/`feedback ~` outside `NOT` uses relevance
(the sum of each condition's score). Otherwise order is updated descending.

```bql
project = BOS AND (status IN (new, "in progress") OR priority >= high)
```
```bql
assignee = currentUser() AND status != done
```
```bql
labels IN (backend, mcp) AND NOT blocked = true ORDER BY priority DESC, updated DESC
```
```bql
created >= 2026-09-01 AND created < 2026-09-15
```
```bql
text ~ "创建任务" AND updated >= -7d
```
```bql
run = failed OR (pr = open AND ci = pending AND merge = waiting)
```
```bql
owner NOT IN (currentUser(), alice) ORDER BY id DESC
```
```bql
ORDER BY created DESC
```

## Saved filters

Use `list_filters`, `save_filter` and `delete_filter`. Creating requires
name (1–80 codepoints, unique per owner/workspace ignoring case) and BQL;
`shared` defaults false. Each owner can save at most 100 filters per
workspace. Updates with `filter_id` change only provided fields; an empty
update leaves the version and notifications unchanged. Optional
`lock_version` rejects stale updates; omit it for last write wins.

Members and above can create filters; viewers and run tokens are read
only. Private filters are visible only to their owner. Shared filters are
readable by everyone, editable/deletable by their owner or admins. Only the
owner can change sharing. Run tokens see shared filters only. Invisible
filters return not found. On leaving a workspace, private filters are
deleted and shared filters remain marked with their owner's departure.

## Compatibility

BQL grammar, aliases and legacy field semantics are compatible with bosun.
Helmsman counts only active feedback; revised records do not count.
Questions stay open until an answer. Full-text matching uses PostgreSQL
and the same Chinese/English tokenization as search, with `ts_rank_cd`
relevance rather than BM25. The page size is 50/200 (bosun uses 100/500).
Errors additionally carry positions. Identity kind, owner, currentUser(),
run, PR, CI, merge and squad fields extend the legacy language. This guide
and implementation are independently authored; no multica assets or code
are included.

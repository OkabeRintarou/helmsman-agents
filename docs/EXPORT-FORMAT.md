# Helmsman export format v1

A gzip UTF-8 JSON snapshot identified by `format: helmsman-export`, `version: 1`.
All object keys sort alphabetically. Times use UTC ISO 8601 with six fractional digits and `Z`.
Identity references are actor names; project references are keys; tasks use `KEY-N`, feedback `KEY-N#M`.
No database IDs, users, memberships, emails, tokens, secrets, runs, provider configuration or repository credentials are exported.

| Object | Fields |
| --- | --- |
| root | actors, exported_at, feedback, format, links, projects, saved_filters, source, task_events, tasks, version, workspace |
| source | app_version, host |
| workspace | name, slug |
| actors | disabled, kind, name, owner |
| projects | archived_at, created_at, description, key, name, task_seq, updated_at |
| tasks | assignee, created_at, created_by, description, epic, id, kind, labels, priority, project, seq, status, title, updated_at |
| task_events | actor, assignee_side, at, auto, auto_reason, comment, commits, feedback, from, n, task, tests, to, verified_sha |
| feedback | at, author, content, fallback, id, kind, mentions, status, superseded_by, supersedes, thread |
| links | actor, at, from, to, type |
| saved_filters | bql, name, owner |

`actors.owner` is the owner's human name, or null; it is informational. Non-agent owners are null.
`disabled` is boolean. Human actors without a user remain visible historically and cannot be assigned until an administrator approves a claim.
Projects include their task number high-water mark; repository bindings remain local.
Task status: new, in_progress, done, verified, rejected, cancelled. Priority: low, medium, high. Kind: task, epic.
Events `n` are consecutive from one in each task, ordered by time then database insertion order. `from` may be null; `to` must match the final task status.
`tests` is null or an object containing command, passed and summary. Commits contain 7–64 hexadecimal characters, matching transition evidence.
Event timestamps must not decrease when ordered by `n`; equal timestamps are allowed and keep `n` order.
Imports reject a decreasing timestamp at `task_events[i].at` before writing any data.
Feedback kind: comment, review, question, answer. Status: active, superseded. Revision links are reciprocal; thread is the first revision's sequence.
Links: depends_on or replaces. depends_on is acyclic. Shared filters contain name, BQL and informational owner; imports create them under the importing user.

Rows sort by actor name, project key, task project key/sequence, event task/n, feedback task/sequence,
link from/to/type, filter owner/name. Derived search and counters are recomputed on import.

Import accepts gzip or uncompressed JSON. Admins may merge; owners may replace with slug confirmation.
Dry run executes the same database writes and rolls them back, retaining its audit report.
Rename mappings apply before identity matching. Existing identities are retained; imported Agents are external.
Replace retains project bindings and number counters, actors, filters and design-only runs.
Task Git branches and daemon worktrees survive replacement and may need manual cleanup.

Squad configuration is outside the snapshot. A newly imported squad becomes a disabled historical identity,
even if its exported `disabled` value was false. This deliberate loss of active squad status prevents dispatch
without a local squad configuration. Existing same-name same-kind actors keep their local disabled status.
For a byte-identical roundtrip of all actor fields, use disabled squads in the source dataset.

# Helmsman export format v2

A gzip UTF-8 JSON snapshot identified by `format: helmsman-export`, `version: 2`.
All object keys sort alphabetically. Times use UTC ISO 8601 with six fractional digits and `Z`.
Identity references are actor names; project references are keys; tasks use `KEY-N`, feedback `KEY-N#M`.
No database IDs, users, memberships, emails, tokens, secrets, runs, provider configuration or repository credentials are exported.
Avatars are not exported either (no image bytes, avatar addresses or keys, for users or identities); imports never create, change or delete an avatar.

| Object | Fields |
| --- | --- |
| root | actors, exported_at, feedback, format, links, projects, saved_filters, source, spec_events, spec_issue_notes, spec_issues, spec_review_requests, spec_reviews, spec_versions, specs, task_events, tasks, version, workspace |
| source | app_version, host |
| workspace | name, slug |
| actors | disabled, kind, name, owner |
| projects | archived_at, created_at, description, key, name, spec_finalize, task_seq, updated_at |
| tasks | assignee, created_at, created_by, description, epic, id, kind, labels, priority, project, seq, status, title, updated_at |
| task_events | actor, assignee_side, at, auto, auto_reason, comment, commits, feedback, from, n, task, tests, to, verified_sha |
| feedback | at, author, content, fallback, id, kind, mentions, reply_root, reply_to, status, superseded_by, supersedes, thread |
| links | actor, at, from, to, type |
| saved_filters | bql, name, owner |
| specs | change_id, created_at, created_by, final_version, latest_version, proposal, status, task |
| spec_versions | at, author, files, n, note, task |
| spec_review_requests | at, close_reason, closed_at, n, note, requested_by, review, reviewer, status, task, version |
| spec_reviews | at, n, reviewer, summary, task, verdict, version |
| spec_issues | anchor, body, file, line, n, review, severity, suggestion, task |
| spec_issue_notes | at, author, body, fixed_in_version, issue, kind, n, resolution, review, task |
| spec_events | action, actor, at, data, n, task, version |

`actors.owner` is the owner's human name, or null; it is informational. Non-agent owners are null.
`disabled` is boolean. Human actors without a user remain visible historically and cannot be assigned until an administrator approves a claim.
Projects include their task number high-water mark; repository bindings remain local.
Task status: new, in_progress, done, verified, rejected, cancelled. Priority: low, medium, high. Kind: task, epic.
Events `n` are consecutive from one in each task, ordered by time then database insertion order. `from` may be null; `to` must match the final task status.
`tests` is null or an object containing command, passed and summary. Commits contain 7–64 hexadecimal characters, matching transition evidence.
Event timestamps must not decrease when ordered by `n`; equal timestamps are allowed and keep `n` order.
Imports reject a decreasing timestamp at `task_events[i].at` before writing any data.
Feedback kind: comment, review, question, answer. Status: active, superseded. Revision links are reciprocal; thread is the first revision's sequence.
Feedback `reply_to` is the original target's `KEY-N#M`; `reply_root` is the root comment's first revision ID.
Both are null for standalone feedback. Replies to replies share one root; revisions preserve both references.
Reply targets and roots must be earlier records in the same task. Older v1 snapshots may omit both fields (treated as null).
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


## Specs in v2

`projects.spec_finalize` is `approval` or `leader`; merge selects it with the newer
project `updated_at`, along with name and description. Squad settings remain local.
Every spec reference uses the task identifier. Versions, requests, reviews and events
have consecutive `n` values starting at 1 within a spec. Issues are numbered within
a review, and notes within an issue. Spec rows sort by task identifier then these numbers.
`spec_versions.files` contains complete original `{path, content}` records sorted by path.
Files obey the spec path, UTF-8, NUL and size rules (64 files, 256 KB per file, 1 MB per
version, 200 versions per spec). Validation and blob hashes are recomputed, not exported.
Versions have no finalized flag: `approved` / `finalized` events preserve every historical
finalization. Issue resolution is derived from the last resolution-setting note.

`specs.proposal` is null or `{version, summary, by, at}`, where `by` is an actor name.
Mutable spec fields and request status/close_reason/review must agree with audit replay;
otherwise validation reports `spec_state_mismatch`. `closed_at` is null for an active
request and a UTC timestamp for a closed request. Run references never enter the snapshot.
Event `data` uses string keys and portable local numbers and actor names.

Spec merge runs independently of task merge. It compares immutable versions, requests
(excluding status, close_reason, review and closed_at), reviews with their issues, notes,
and audit events. All local sequences prefix the import: fast-forward; all import
sequences prefix local: local newer; equal: unchanged; any fork or crossed progress:
`diverged` and complete rollback. Spec `updated_at` never selects a winner. A conflicting
local change ID on another task produces `change_id_conflict`. Import replays state,
recomputes issue resolutions and version validation, and never dispatches imported requests.
Replace removes old specs and all their descendants alongside tasks.

## Compatibility with v1

Import still accepts `helmsman-export` version 1, including Bosun-converted snapshots.
v1 has the original seven arrays (actors, projects, tasks, task_events, feedback, links,
saved_filters), no spec arrays, and no project `spec_finalize`; the missing project setting
defaults to `approval`. A v1 merge leaves local specs intact. A v1 replace still deletes
old task specs. Export always writes v2 so older servers explicitly reject the version
instead of silently discarding specs. Versions other than 1 and 2 are unsupported.

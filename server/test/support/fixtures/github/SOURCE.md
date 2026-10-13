# GitHub API response fixtures

Response bodies of the GitHub REST and GraphQL APIs used by
`Helmsman.FakeGitHub` (`add-pr-reconcile-merge` tests). Only bodies are
stored, never request or response headers.

| file | request | source |
|---|---|---|
| `pull.json` | `GET /repos/{o}/{r}/pulls/{n}` (also the items of `GET /pulls?head=&base=&state=open` and the bodies of `POST /pulls`, `PATCH /pulls/{n}`) | hand-written from the GitHub REST docs (2022-11-28), 2026-10-13 |
| `merge_200.json` | `PUT /pulls/{n}/merge` 200 | hand-written, 2026-10-13 |
| `merge_405_conflict.json` | `PUT /pulls/{n}/merge` 405 (conflict; `GET` then shows `mergeable_state: dirty`) | hand-written, 2026-10-13 |
| `merge_405_checks.json` | `PUT /pulls/{n}/merge` 405 (required check not finished) | hand-written, 2026-10-13 |
| `merge_409.json` | `PUT /pulls/{n}/merge` 409 (head moved) | hand-written, 2026-10-13 |
| `create_422_exists.json` | `POST /pulls` 422, a pull request already exists | hand-written, 2026-10-13 |
| `create_422_draft.json` | `POST /pulls` 422, drafts not supported | hand-written, 2026-10-13 |
| `create_422_head.json` | `POST /pulls` 422, invalid head (branch missing) | hand-written, 2026-10-13 |
| `compare.json` | `GET /compare/{base}...{head}` | hand-written, 2026-10-13 |
| `check_runs.json` | `GET /commits/{sha}/check-runs` | hand-written, 2026-10-13 |
| `status.json` | `GET /commits/{sha}/status` | hand-written, 2026-10-13 |
| `ref.json` | `GET /git/ref/heads/{branch}`, `POST /git/refs` 201 | hand-written, 2026-10-13 |
| `ref_422.json` | `DELETE /git/refs/heads/{branch}` 422 (already gone) | hand-written, 2026-10-13 |
| `graphql_draft.json`, `graphql_ready.json` | `POST /graphql` `convertPullRequestToDraft` / `markPullRequestReadyForReview` | hand-written, 2026-10-13 |

Task 1.12 replaces these with responses recorded against a test
repository and adds the `ahead` / `diverged` compares, the re-created ref
after a delete and the `head`+`base` lookup.

## Redaction rules

Private values are replaced with fixed placeholders before a file is
stored: tokens are never stored; owner `acme`, repository `app`;
numeric IDs (`id`, installation IDs) with small integers; `node_id`s with
`PR_kwDOAAAAAA`-style placeholders; e-mail addresses with
`user@example.com`; SHAs with 40 zeros (tests fill in their own).

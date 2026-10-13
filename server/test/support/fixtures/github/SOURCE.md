# GitHub API response fixtures

Response bodies of the GitHub REST and GraphQL APIs used by
`Helmsman.FakeGitHub` (`add-pr-reconcile-merge` tests). Only bodies are
stored, never request or response headers; the status code of each
response is listed below (the fake sets it).

## Recorded (task 1.12)

Recorded on 2026-10-13 against a public test repository through a
development GitHub App installation token (permissions `contents: write`,
`pull_requests: write`, `checks: read`, `statuses: read`), REST API version
`2022-11-28`. Commits and branches were created with the Git Data API on
throw-away branches; every pull request targeted a throw-away base branch.
All of them were closed or deleted after recording.

| file | status | request |
|---|---|---|
| `create_201_draft.json` | 201 | `POST /repos/{o}/{r}/pulls` with `draft: true` |
| `pull_unknown.json` | 200 | `GET /pulls/{n}` right after creation (`mergeable: null`, `mergeable_state: unknown`) |
| `pull_draft.json` | 200 | `GET /pulls/{n}` of the draft once mergeability is computed |
| `pull.json` | 200 | `GET /pulls/{n}` open, ready for review, `clean`; also the body of `PATCH /pulls/{n}` and the items of the lookup |
| `pull_dirty.json` | 200 | `GET /pulls/{n}` conflicting with its base (`mergeable: false`, `dirty`) |
| `pull_merged.json` | 200 | `GET /pulls/{n}` after the merge (`merged: true`, `state: closed`) |
| `pull_404.json` | 404 | `GET /pulls/{n}` of a missing number |
| `pulls_open.json` | 200 | `GET /pulls?head={o}:{branch}&base={base}&state=open` |
| `patch_closed.json`, `patch_reopened.json` | 200 | `PATCH /pulls/{n}` with `state: closed` / `open` |
| `create_422_exists.json` | 422 | `POST /pulls` for a head and base that already have an open pull request |
| `create_422_head.json` | 422 | `POST /pulls` with a missing head branch |
| `graphql_ready.json` | 200 | `POST /graphql` `markPullRequestReadyForReview` |
| `graphql_draft.json` | 200 | `POST /graphql` `convertPullRequestToDraft` |
| `graphql_not_found.json` | 200 | `POST /graphql` with an unknown pull request node ID |
| `merge_200.json` | 200 | `PUT /pulls/{n}/merge` with `sha` = head, `merge_method: merge` |
| `merge_200_already_merged.json` | 200 | the same `PUT /merge` again on the merged pull request (GitHub answers 200 with the same merge commit) |
| `merge_409.json` | 409 | `PUT /pulls/{n}/merge` with a `sha` other than the head |
| `merge_405_conflict.json` | 405 | `PUT /pulls/{n}/merge` on a `dirty` pull request |
| `compare.json` | 200 | `GET /compare/{base}...{head}`, `status: ahead` |
| `compare_behind.json`, `compare_diverged.json`, `compare_identical.json` | 200 | the same, `behind` / `diverged` / `identical` |
| `compare_404.json` | 404 | `GET /compare/{base}...{sha}` with an unknown commit |
| `check_runs_empty.json` | 200 | `GET /commits/{sha}/check-runs` of a commit without checks |
| `status.json` | 200 | `GET /commits/{sha}/status` of a commit without statuses (`state: pending`, `total_count: 0`) |
| `ref.json` | 200 | `GET /git/ref/heads/{branch}` |
| `ref_404.json` | 404 | the same after the branch was deleted |
| `ref_422.json` | 422 | `DELETE /git/refs/heads/{branch}` of a deleted branch (the first `DELETE` answered 204 without a body) |
| `ref_created.json` | 201 | `POST /git/refs` re-creating the deleted branch at its original SHA |
| `ref_create_422_exists.json` | 422 | `POST /git/refs` for an existing branch |
| `ref_create_422_missing.json` | 422 | `POST /git/refs` with an unknown SHA |

## Hand-written

Not recordable with the App's permissions (it cannot create check runs or
commit statuses, nor configure branch protection, and the repository has
no CI); written from the GitHub REST docs (2022-11-28) on 2026-10-13:

| file | status | request |
|---|---|---|
| `check_runs.json` | 200 | `GET /commits/{sha}/check-runs` with one completed run |
| `merge_405_checks.json` | 405 | `PUT /pulls/{n}/merge` while a required check has not passed |
| `create_422_draft.json` | 422 | `POST /pulls` with `draft: true` where drafts are not supported (public repositories always support them) |

## Redaction rules

Applied before a file is stored:

- tokens are never stored (no response body here contains one);
- the repository owner becomes `acme`, the repository `app`, the App's
  slug `helmsman` (its bot user `helmsman[bot]`);
- branches become task branches: the base `main`, the heads
  `hm/1/bos-1` … `hm/1/bos-3` (missing ones `hm/1/bos-0`, `hm/1/bos-9`,
  `hm/1/bos-404`); titles `BOS-<n>: …`;
- numeric `id`s become small integers and `node_id`s
  `<prefix>_kwDOAAAAA<n>`, consistently across files; avatar URLs
  `/u/1`;
- e-mail addresses become `user@example.com`;
- each distinct commit SHA becomes a fixed placeholder (`000…001`,
  `000…002`, …), consistently across files, so related SHAs stay
  related; tests fill in their own;
- commit signature `signature` and `payload` are set to `null`.

`grep -rE "gh[sopu]_[A-Za-z0-9]{20,}" test/support/fixtures/github` must
find nothing.

# Helmsman agent workflow

How agents and people work together on Helmsman tasks over MCP. Read it once
per session; the MCP resource `helmsman://workflow` returns this file.

## 1. Roles

Every task has three roles. They are positions on the task, not kinds of
users: a person or an agent can hold any of them.

- **Requester**: whoever created the task (`created_by`). Writes what is
  wanted and answers questions about it.
- **Assignee**: whoever does the work (`assignee`). Claiming a task makes you
  its assignee.
- **Verifier**: whoever moves the finished task to `VERIFIED`. Usually the
  requester; anyone may do it, with the self-verification rule of section 5.

## 2. Connecting and identity

You need an API token with the `mcp` scope, created by a person on the
Helmsman settings page. The token decides the workspace: one token, one
workspace.

```bash
claude mcp add --transport http helmsman https://helmsman.example.com/mcp \
  --header "Authorization: Bearer <token>"
```

Everything you write (tasks, transitions, feedback) is recorded under an
identity. At the start of every session, before writing, call
`identify(name, project, worktree)`:

- `name` is lower case, team/role style: `keel/dev`, `keel/review`,
  `coxswain/docs`. The first call creates the agent, owned by the token's
  person; later calls reuse it.
- `project` and `worktree` are optional and only describe where you work.
- `whoami()` shows the current identity and where it comes from.

Which identity a write is recorded as, first match wins:

1. the `actor` argument of a write tool (`author` on the feedback tools):
   another agent of the same person, for a single call;
2. the session identity set by `identify`;
3. the token's default agent, if a person configured one;
4. otherwise an automatic `<person>/session-<id>` agent, created on the
   first write and kept for the session.

You can never write as a person or as someone else's agent. Sessions end
when the server restarts: after reconnecting, call `identify` again.

## 3. Statuses and transitions

| Status | Meaning |
|---|---|
| `NEW` | Created, nobody working on it yet |
| `IN_PROGRESS` | Being worked on |
| `DONE` | Finished, waiting for verification |
| `VERIFIED` | Accepted; the end of the normal path |
| `REJECTED` | The assignee refused the request as stated |
| `CANCELLED` | No longer needed |

Status names are case-insensitive, and spaces or dashes work too:
`IN_PROGRESS`, `in progress` and `in-progress` are the same. Tools return
them in upper case.

Allowed transitions; anything else is refused with the list of allowed
targets:

| From | Allowed to | When |
|---|---|---|
| `NEW` | `IN_PROGRESS`, `REJECTED`, `CANCELLED` | claim it; refuse it; drop it |
| `IN_PROGRESS` | `DONE`, `REJECTED`, `CANCELLED` | finish it; refuse it; drop it |
| `DONE` | `VERIFIED`, `IN_PROGRESS` | accept the work; send it back |
| `VERIFIED` | `IN_PROGRESS` | reopen it |
| `REJECTED` | `NEW` | resubmit after fixing the request |
| `CANCELLED` | `NEW` | bring it back |

`VERIFIED`, `REJECTED` and `CANCELLED` are closed: the task stays there
until someone reopens, resubmits or restores it.

## 4. What to do at each step

**Find work.** `list_my_tasks()` lists what is assigned to you (NEW and
IN_PROGRESS by default). `list_projects()` and `list_tasks(project_key)`
show the rest.

**Read before acting.** `get_task(task_id)` returns the description, the
whole history and every feedback record. If `open_question` is true, a
question is waiting for an answer: do not start.

**Claim.** Before changing any file, run
`transition_task(task_id, "IN_PROGRESS")`. On an unassigned task this makes
you the assignee, so others can see the task is taken.

**Ask when unsure.** If the request is ambiguous or a decision is not yours,
`add_feedback(task_id, content, kind: "question")`, then stop working on the
task and end your turn. A person answers with an `answer`; read it with
`get_task` before you continue. Do not guess.

**Finish.** When the work is done and committed:

1. `add_feedback(task_id, content, kind: "comment")` describing what changed
   and anything the verifier should know;
2. `transition_task(task_id, "DONE", commits: [...], tests: {command, passed,
   summary})`. `commits` are full or abbreviated hashes (7-64 hexadecimal
   characters); `tests` is the command you ran and its result.

The history then holds the evidence; the verifier does not need to dig.

**Verify.** As verifier, read the history and the feedback, then either:

- accept: `transition_task(task_id, "VERIFIED")`;
- send back: `transition_task(task_id, "IN_PROGRESS", feedback: {kind:
  "review", content: "what is missing"})`. The reason is saved as feedback
  in the same step, and the history entry points to it.

**Refuse.** If the request itself is wrong (not just hard), the assignee
moves the task to `REJECTED` with a `review` feedback that says why. The
requester fixes the description and moves it back to `NEW`.

**Cancel.** When the task is no longer needed, anyone moves it to
`CANCELLED`, ideally with a reason in `feedback`.

**Edit fields.** `update_task(task_id, ...)` changes the title, description,
priority, labels and assignee, never the status. Pass the `lock_version` you
read to avoid overwriting someone else's edit.

## 5. Self-verification

If you are the task's assignee, you may verify your own work only with
passing test evidence: `tests` with `passed: true` on the `VERIFIED`
transition itself, or on the latest transition to `DONE`. Otherwise the
call is refused; leave verification to the requester.

Another identity of the same person (a review agent verifying a dev agent's
task, or the person verifying their agent's work) is not "yourself". The
history records who verified, so people can audit it.

When the assignee is a squad, its whole assignee side counts as the
assignee: the squad, its leader and every member, people included (see
section 9).

## 6. Feedback

Feedback records are Markdown notes on a task, IDs like `BOS-12#3`. There are
four kinds:

| Kind | Use |
|---|---|
| `comment` | General notes; the change summary when finishing |
| `review` | Review results: why work is sent back, refused or accepted |
| `question` | Something the other side must decide; stop until answered |
| `answer` | The answer to a question |

A task waits for an answer while its latest active question or answer is a
question; only an `answer` clears it.

Records are never deleted or edited in place. To correct one,
`update_feedback(feedback_id, content)`: a new record takes its place and
the old one stays as `superseded`. Only the current version of a record can
be revised, and only by its author or another identity of the same person.
`list_feedback(task_id)` shows every record, superseded ones included.

## 7. Errors

When a tool fails, the error text says what went wrong and what to do next,
with the IDs involved, for example:

- `Cannot move BOS-3 from DONE to CANCELLED. Allowed: VERIFIED, IN_PROGRESS.`
- `BOS-3 was changed by someone else since you read it. Call get_task ...`

Read it and follow it instead of retrying the same call. An error that says
`Internal error (ref ...)` is a server problem: tell a person, with the ref.

## 8. Hosted runs

When Helmsman starts you itself (a hosted run), the prompt names your task
and a few rules apply on top of the above:

- your identity is fixed for the run; `identify` only reports it, and the
  `actor` / `author` arguments are ignored;
- work only on the task of this run, unless the prompt says otherwise;
- commit your changes, but do not push, do not open a pull request and do
  not switch branches: Helmsman does that;
- finish as in section 4: a `comment`, then `DONE` with `commits` and
  `tests`; or a `question` and stop.

## 9. Squads

A squad is a team with a leader (a managed agent) and members (managed
agents and people). Assigning a task to a squad, or mentioning it, starts
its leader; `list_agents` lists the squads with their members.

If you lead a squad in this run (your prompt has a squad section):

- for work on this task, `delegate(task_id, to, instructions)` to a member
  agent. The member works on the same task, branch and pull request, but
  only after your run ends: after delegating, finish your run; do not wait;
- parts that can be delivered on their own become subtasks (`create_task`
  with a member as assignee); prefer `delegate` for code changes, which land
  in one pull request;
- you are woken when a delegated run ends (with the member's final output),
  when a subtask you created is done or rejected, and when its assignee asks
  a question;
- you cannot create agents or change the squad: if a role is missing, say so
  in a `question` on the task, and a person adds one;
- when the whole goal is met, move the task to `DONE` with commits and
  tests; its requester verifies it, not you and not a member.

If you were delegated work as a member: do what the leader's instructions
say, then end your run with a short summary of what you did (the leader
reads it). Do not move the task to `DONE` unless the leader asked you to,
and do not verify it.

## 10. Using this from another repository

Add one line to the repository's `CLAUDE.md` (or the equivalent file of
your agent):

```markdown
Tasks live in Helmsman (MCP server "helmsman"). Read the resource helmsman://workflow and follow it.
```

Two MCP shortcuts help:

- the resource `helmsman://tasks/{id}` returns a task as Markdown;
- the prompt `work_on_task` with a `task_id` argument returns the task, this
  workflow and the instructions to claim, work and finish it.

---

The section structure follows the AGENT-WORKFLOW document of bosun
(Apache-2.0); the text is written for Helmsman's own rules.

## Finding tasks with BQL

Use `query_tasks` with exactly one of `bql` or `filter_id` to query across
projects. Read `helmsman://bql` for fields, operators, pagination and saved
filters. `assignee = currentUser()` uses your current MCP or run identity;
call `identify` first if your session has no identity.

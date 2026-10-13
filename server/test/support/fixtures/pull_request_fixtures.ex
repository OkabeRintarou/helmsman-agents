defmodule Helmsman.PullRequestFixtures do
  @moduledoc """
  Test helpers for `add-pr-reconcile-merge`: a task of `keel/dev` whose
  project is bound to `acme/app`, runs with push records, verifications,
  pull request rows and a programmable GitHub stub (`github_stub/1`).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.GitHub.PullRequest
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{GitRepo, Run}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.TaskEvent
  alias Helmsman.Tx

  @doc """
  `dispatch_fixture/0` plus an installation, the repository `acme/app`
  bound to the project and a task assigned to `keel/dev` (its dispatched
  run cancelled), with its task branch (`branch`) and the daemon.
  """
  def pr_fixture(opts \\ []) do
    ctx = dispatch_fixture(Keyword.get(opts, :agent_attrs, %{}))
    installation = installation_fixture(ctx.workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repository)
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    cancel_pending(task)

    Map.merge(ctx, %{
      installation: installation,
      repository: repository,
      task: Repo.reload!(task),
      daemon: daemon_of(ctx.agent),
      branch: GitRepo.branch(ctx.workspace.id, task.ident),
      system: system_actor(ctx.workspace)
    })
  end

  @doc "Cancels the pending runs of `task`."
  def cancel_pending(task) do
    Tx.run(fn ->
      {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
    end)
  end

  @doc "The workspace's system identity."
  def system_actor(workspace),
    do:
      Repo.one!(
        from(a in Helmsman.Actors.Actor,
          where: a.workspace_id == ^workspace.id and a.kind == :system
        )
      )

  @doc """
  A run of the fixture's task that pushed `head` on `base` (succeeded by
  default). `attrs` may set `agent` (an actor), `status`,
  `repository_id`, `rescue_branch` (a `conflict` push), `causal_agent_ids`
  and `claimed_at`.
  """
  def pushed_run(ctx, head, base, attrs \\ %{}) do
    attrs = Map.new(attrs)
    agent = Map.get(attrs, :agent, ctx.agent)
    rescue_branch = Map.get(attrs, :rescue_branch)
    status = Map.get(attrs, :status, :succeeded)
    now = DateTime.utc_now()

    run_fixture(
      agent,
      Map.merge(
        %{
          task_id: ctx.task.id,
          status: status,
          daemon_id: daemon_of(agent).id,
          claimed_at: Map.get(attrs, :claimed_at, now),
          started_at: now,
          finished_at: if(status in Run.ended_statuses(), do: now),
          repository_id: ctx.repository.id,
          branch: ctx.branch,
          base_sha: base,
          head_sha: head,
          push_status: if(rescue_branch, do: :conflict, else: :pushed),
          rescue_branch: rescue_branch,
          push_commits: [],
          pushed_at: now
        },
        Map.drop(attrs, [:agent, :status, :rescue_branch, :claimed_at])
      )
    )
  end

  @doc "Moves `task` through `statuses` as `scope` (`opts` for the last)."
  def move(scope, task, statuses, opts \\ %{}) do
    {last, path} = List.pop_at(statuses, -1)
    for to <- path, do: {:ok, _} = Tasks.transition(scope, task.ident, to)
    Tasks.transition(scope, task.ident, last, opts)
  end

  @doc "The latest move of `task` to `verified`."
  def latest_verification(task),
    do:
      Repo.one(
        from(e in TaskEvent,
          where: e.task_id == ^task.id and e.to_status == :verified,
          order_by: [desc: e.id],
          limit: 1
        )
      )

  @doc "Inserts a pull request row of the fixture's task."
  def pr_row(ctx, attrs \\ %{}) do
    attrs = Map.new(attrs)
    number = Map.get(attrs, :number, System.unique_integer([:positive]))
    repository = Map.get(attrs, :repository, ctx.repository)

    Repo.insert!(
      struct!(
        PullRequest,
        Map.merge(
          %{
            workspace_id: ctx.workspace.id,
            task_id: ctx.task.id,
            repository_id: repository.id,
            number: number,
            node_id: "PR_node_#{number}",
            url: "https://github.com/#{repository.owner}/#{repository.name}/pull/#{number}",
            branch: ctx.branch,
            base_branch: "main",
            state: :open
          },
          Map.drop(attrs, [:repository])
        )
      )
    )
  end

  @doc "A 40-character lower-case SHA made of `char`."
  def sha(char), do: String.duplicate(char, 40)
end

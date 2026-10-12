defmodule Helmsman.GitRunFixtures do
  @moduledoc """
  Test helpers for `add-daemon-git-workspace`: a task whose project is
  bound to `acme/app`, with a run claimed by the agent's daemon on that
  repository.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Repo
  alias Helmsman.Runs.{GitRepo, Run}

  @doc """
  `dispatch_fixture/0` plus an installation, the repository `acme/app`
  bound to the project, a task and `run` of it `running` on the agent's
  daemon with the repository and task branch (`branch`).
  """
  def git_run_fixture do
    ctx = dispatch_fixture()
    installation = installation_fixture(ctx.workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repository)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    daemon = daemon_of(ctx.agent)
    branch = GitRepo.branch(ctx.workspace.id, task.ident)

    run =
      claimed_git_run(
        Map.merge(ctx, %{daemon: daemon, task: task, repository: repository, branch: branch})
      )

    Map.merge(ctx, %{
      installation: installation,
      repository: repository,
      task: task,
      daemon: daemon,
      dctx: daemon_ctx(daemon),
      branch: branch,
      run: run
    })
  end

  @doc "Another run of the fixture's task, `running` on its daemon by default."
  def claimed_git_run(ctx, attrs \\ %{}) do
    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          task_id: ctx.task.id,
          status: :running,
          daemon_id: ctx.daemon.id,
          claimed_at: DateTime.utc_now(),
          started_at: DateTime.utc_now(),
          repository_id: ctx.repository.id,
          branch: ctx.branch
        },
        attrs
      )
    )
  end

  @doc "Sets columns of `run` directly."
  def set_run(%Run{id: id}, changes) do
    Repo.update_all(from(r in Run, where: r.id == ^id), set: changes)
    Repo.get!(Run, id)
  end

  @doc "A 40-character lower-case SHA made of `char`."
  def sha(char), do: String.duplicate(char, 40)
end

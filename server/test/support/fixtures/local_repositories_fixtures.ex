defmodule Helmsman.LocalRepositoriesFixtures do
  @moduledoc """
  Test helpers for `add-local-repositories`: local repository rows, their
  reports, project bindings and a task with a local-mode run.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.LocalRepositories.{LocalRepository, TaskLocalBranch}
  alias Helmsman.Repo
  alias Helmsman.Runs.{GitRepo, Run}
  alias HelmsmanProtocol.Report

  @doc "Inserts a local repository of `daemon` in `workspace` (`online` by default)."
  def local_repository_fixture(workspace, daemon, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        LocalRepository,
        Map.merge(
          %{
            workspace_id: workspace.id,
            daemon_id: daemon.id,
            name: "app",
            path: "/home/alice/code/app",
            default_branch: "main",
            status: "online"
          },
          attrs
        )
      )
    )
  end

  @doc "Binds `project` to the local repository directly (and its base branch)."
  def bind_local(project, %LocalRepository{} = repo, base_branch \\ nil) do
    project
    |> Ecto.Changeset.change(local_repository_id: repo.id, base_branch: base_branch)
    |> Repo.update!()
  end

  @doc "A reported local repository (`HelmsmanProtocol.LocalRepository`)."
  def local_report(name, workspace_ids, attrs \\ %{}) do
    struct!(
      HelmsmanProtocol.LocalRepository,
      Map.merge(
        %{
          name: name,
          path: "/home/alice/code/#{name}",
          workspaces: workspace_ids,
          default_branch: "main",
          available: true,
          unavailable_reason: nil
        },
        attrs
      )
    )
  end

  @doc "A protocol-3 join report with `local_repositories` and no CLI."
  def local_join(local_repositories, protocol \\ HelmsmanProtocol.version()) do
    %Report.Join{
      protocol: protocol,
      machine: %HelmsmanProtocol.Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"},
      clis: [],
      max_concurrency: 4,
      active_runs: [],
      local_repositories: local_repositories
    }
  end

  @doc """
  `dispatch_fixture/0` with the project bound to a local repository `app`
  of the agent's daemon, a task and its task branch.
  """
  def local_run_fixture do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    repo = local_repository_fixture(ctx.workspace, daemon)
    project = bind_local(ctx.project, repo)
    task = task_fixture(ctx.alice_scope, project.key)

    Map.merge(ctx, %{
      project: project,
      daemon: daemon,
      dctx: daemon_ctx(daemon),
      local_repo: repo,
      task: task,
      branch: GitRepo.branch(ctx.workspace.id, task.ident)
    })
  end

  @doc "A run of the fixture's task claimed on its daemon in local mode (`running`)."
  def local_run(ctx, attrs \\ %{}) do
    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          task_id: ctx.task.id,
          status: :running,
          daemon_id: ctx.daemon.id,
          claimed_at: DateTime.utc_now(),
          started_at: DateTime.utc_now(),
          local_repository_id: ctx.local_repo.id,
          branch: ctx.branch
        },
        attrs
      )
    )
  end

  @doc "The task's local branch row, or nil."
  def local_branch(task_id), do: Repo.get_by(TaskLocalBranch, task_id: task_id)

  @doc "Sets columns of `run` directly."
  def set_local_run(%Run{id: id}, changes) do
    Repo.update_all(from(r in Run, where: r.id == ^id), set: changes)
    Repo.get!(Run, id)
  end
end

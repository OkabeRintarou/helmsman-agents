defmodule Helmsman.Runs.LocalRepo do
  @moduledoc """
  The local repository of a run's description (`add-local-repositories`
  decisions 6, 13): a run whose project is bound to a local repository can
  only run on that repository's machine. Resolved inside the claim
  transaction from a snapshot of the project and the repository (no
  locks; a later change of binding does not affect a claimed run).

  The description carries the repository's name, never its path; there is
  no push token (the daemon pushes to a path on its own machine).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Autopilots
  alias Helmsman.Daemons.Daemon
  alias Helmsman.LocalRepositories.LocalRepository
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{GitRepo, Run}
  alias Helmsman.Tasks.Task

  @type t :: %{
          required(:kind) => :local,
          required(:local_repository) => LocalRepository.t(),
          required(:daemon_name) => String.t(),
          required(:base_branch) => String.t(),
          required(:branch) => String.t() | nil,
          required(:rescue_branches) => [String.t()],
          optional(:mode) => :task | :snapshot
        }

  @doc """
  The local repository of the run being claimed by `daemon` over a
  connection of protocol `protocol`; `task` is the locked task row.

    * `:none` - no task, or its project is not bound to a local repository;
    * `{:unavailable, message}` - the repository is on another machine,
      removed or unavailable, the connection is older than
      `HelmsmanProtocol.local_repositories_version/0`, or there is no base
      branch (neither the project's nor the repository's default branch);
    * `{:ok, repo}` - name, machine, base and task branches and the rescue
      branches to merge.
  """
  @spec resolve(Run.t(), Task.t() | nil, Daemon.t(), pos_integer()) ::
          :none | {:unavailable, String.t()} | {:ok, t()}
  def resolve(%Run{} = run, nil, %Daemon{} = daemon, protocol) do
    case Autopilots.run_project(run) do
      %Project{local_repository_id: id} = project when is_integer(id) ->
        check(run, nil, project, Repo.get!(LocalRepository, id), daemon, protocol)

      _none ->
        :none
    end
  end

  def resolve(%Run{} = run, %Task{} = task, %Daemon{} = daemon, protocol) do
    project = Repo.get!(Project, task.project_id)

    case project.local_repository_id do
      nil -> :none
      id -> check(run, task, project, Repo.get!(LocalRepository, id), daemon, protocol)
    end
  end

  defp check(run, task, project, repo, daemon, protocol) do
    machine = Repo.one!(from(d in Daemon, where: d.id == ^repo.daemon_id, select: d.name))
    version = HelmsmanProtocol.local_repositories_version()
    base_branch = project.base_branch || repo.default_branch

    cond do
      repo.daemon_id != daemon.id ->
        {:unavailable,
         "This project's repository #{repo.name} is on #{machine}; " <>
           "the agent's runtime is on another machine"}

      repo.removed_at != nil ->
        {:unavailable, "Local repository #{repo.name} on #{machine} was removed"}

      repo.status == "unavailable" ->
        {:unavailable,
         "Local repository #{repo.name} on #{machine} is not available: " <>
           repo.unavailable_reason}

      protocol < version ->
        {:unavailable,
         "Local repository #{repo.name} needs a newer daemon: upgrade the daemon on " <>
           "#{machine} (protocol #{version} or later)"}

      is_nil(base_branch) ->
        {:unavailable,
         "Local repository #{repo.name} on #{machine} has no base branch: set the " <>
           "project's base branch"}

      # `add-autopilots` decision 13: a run-only autopilot run checks the
      # base branch out read-only.
      is_nil(task) ->
        {:ok,
         %{
           kind: :local,
           mode: :snapshot,
           local_repository: repo,
           daemon_name: machine,
           base_branch: base_branch,
           branch: nil,
           rescue_branches: []
         }}

      true ->
        {:ok,
         %{
           kind: :local,
           local_repository: repo,
           daemon_name: machine,
           base_branch: base_branch,
           branch: GitRepo.branch(run.workspace_id, task.ident),
           rescue_branches: rescue_branches(task.id, repo.id)
         }}
    end
  end

  @doc """
  The rescue branches left by runs of task `task_id` on local repository
  `local_repository_id` (`push_status = conflict`), without duplicates, in
  the order of the runs.
  """
  @spec rescue_branches(pos_integer(), pos_integer()) :: [String.t()]
  def rescue_branches(task_id, local_repository_id) do
    Repo.all(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.local_repository_id == ^local_repository_id and
            r.push_status == :conflict,
        order_by: [asc: r.id],
        select: r.rescue_branch
      )
    )
    |> Enum.uniq()
  end
end

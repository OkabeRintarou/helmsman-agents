defmodule Helmsman.Runs.GitRepo do
  @moduledoc """
  The repository of a run's description (`add-daemon-git-workspace`
  decision 2): a run with a task whose project is bound to a repository
  works in a git worktree of the task branch `hm/<workspace_id>/<ident in
  lower case>`.

  Push tokens are fetched before the claim transaction
  (`prefetch_push_tokens/1`, HTTP never runs inside it); the claim
  resolves each candidate's repository from a snapshot of its project,
  repository and installation (`resolve/3`): no repository, unavailable
  (the run fails with `workspace_prepare`), available without a token
  (the run stays queued) or available with one.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Daemons
  alias Helmsman.Daemons.Daemon
  alias Helmsman.GitHub
  alias Helmsman.GitHub.{Client, Installation, Repositories, Repository}
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{Claim, Lifecycle, Run}
  alias Helmsman.Tasks.Task

  @max_prefetch 20

  @type token :: %{token: String.t(), expires_at: DateTime.t()}
  @type tokens :: %{pos_integer() => token()}
  @type t :: %{
          repository: Repository.t(),
          base_branch: String.t(),
          branch: String.t(),
          rescue_branches: [String.t()],
          token: token()
        }

  @doc "The task branch of task `ident` in workspace `workspace_id`."
  @spec branch(pos_integer(), String.t()) :: String.t()
  def branch(workspace_id, ident), do: "hm/#{workspace_id}/" <> String.downcase(ident)

  @doc "The clone URL of `repository` (never with credentials)."
  @spec clone_url(Repository.t()) :: String.t()
  def clone_url(%Repository{owner: owner, name: name}),
    do: "#{Client.web_url()}/#{owner}/#{name}.git"

  @doc """
  Push tokens for the repositories the daemon of `ctx` may claim runs of
  now: those of the projects of its due `queued` runs on the runtimes it
  can claim from, available, at most #{@max_prefetch}, by their earliest
  queued run. Reads without locks and outside any transaction; a token
  GitHub does not give (unreachable, rate limited) is left out and
  logged. The map is only used by the following claim.
  """
  @spec prefetch_push_tokens(Lifecycle.daemon_ctx()) :: tokens()
  def prefetch_push_tokens(%{daemon_id: daemon_id, auth_epoch: epoch}) do
    with %Daemon{} = daemon <- Repo.get(Daemon, daemon_id),
         :ok <- Daemons.authorized(daemon, epoch),
         [_ | _] = ids <- Claim.runtime_ids(daemon) do
      ids
      |> due_repositories()
      |> Enum.reduce(%{}, &fetch_token/2)
    else
      _none -> %{}
    end
  end

  defp due_repositories(runtime_ids) do
    Repo.all(
      from(r in Run,
        join: t in Task,
        on: t.id == r.task_id,
        join: p in Project,
        on: p.id == t.project_id,
        join: repo in Repository,
        on: repo.id == p.repository_id and repo.workspace_id == r.workspace_id,
        join: i in Installation,
        on: i.id == repo.installation_id,
        where:
          r.runtime_id in ^runtime_ids and r.status == :queued and
            r.not_before <= ^DateTime.utc_now() and is_nil(repo.removed_at) and
            not repo.archived and is_nil(i.disconnected_at) and is_nil(i.suspended_at),
        group_by: repo.id,
        order_by: [asc: min(r.inserted_at), asc: repo.id],
        limit: @max_prefetch,
        select: repo
      )
    )
  end

  defp fetch_token(%Repository{} = repository, tokens) do
    case GitHub.push_token(repository) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        Map.put(tokens, repository.id, %{token: token, expires_at: expires_at})

      {:error, reason} ->
        Logger.warning(
          "no push token for repository #{repository.owner}/#{repository.name} " <>
            "(#{repository.id}): #{inspect(reason)}"
        )

        tokens
    end
  end

  @doc """
  The repository of the run being claimed, read inside the claim
  transaction (no locks: a snapshot is enough, a later change of binding
  does not affect a claimed run). `task` is the locked task row (nil
  without a task).

    * `:none` - no task, or its project is not bound to a repository;
    * `{:unavailable, message}` - removed, archived or its installation
      disconnected or suspended;
    * `:no_token` - available, but `tokens` has no token for it;
    * `{:ok, repo}` - the repository, base and task branches, the rescue
      branches to merge and the push token.
  """
  @spec resolve(Run.t(), Task.t() | nil, tokens()) ::
          :none | :no_token | {:unavailable, String.t()} | {:ok, t()}
  def resolve(%Run{}, nil, _tokens), do: :none

  def resolve(%Run{} = run, %Task{} = task, tokens) do
    project = Repo.get!(Project, task.project_id)

    case project.repository_id && Repositories.get(run.workspace_id, project.repository_id) do
      nil ->
        :none

      {repository, installation} ->
        cond do
          not Repositories.available?(repository, installation) ->
            {:unavailable,
             "Repository #{repository.owner}/#{repository.name} is not available " <>
               "(removed, archived, or the GitHub installation is disconnected)"}

          token = Map.get(tokens, repository.id) ->
            {:ok,
             %{
               repository: repository,
               base_branch: project.base_branch || repository.default_branch,
               branch: branch(run.workspace_id, task.ident),
               rescue_branches: rescue_branches(task.id, repository.id),
               token: token
             }}

          true ->
            :no_token
        end
    end
  end

  @doc """
  The rescue branches left by runs of task `task_id` on repository
  `repository_id` (`push_status = conflict`), without duplicates, in the
  order of the runs.
  """
  @spec rescue_branches(pos_integer(), pos_integer()) :: [String.t()]
  def rescue_branches(task_id, repository_id) do
    Repo.all(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.repository_id == ^repository_id and
            r.push_status == :conflict,
        order_by: [asc: r.id],
        select: r.rescue_branch
      )
    )
    |> Enum.uniq()
  end
end

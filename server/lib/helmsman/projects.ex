defmodule Helmsman.Projects do
  @moduledoc """
  Projects (designs/04 §1): created, renamed, archived and restored by
  admins and above; read by every member.

  Keys are looked up case-insensitively. Projects are never deleted. Every
  committed change broadcasts `{:projects_changed}` on the workspace topic.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Events
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Repositories
  alias Helmsman.GitHub.Repository
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type error :: Ecto.Changeset.t() | :forbidden | :not_found | atom()

  ## Creating

  @doc """
  Creates a project (`:create_project`) from `key`, `name` and an optional
  `description`. The key is upcased before validation.
  """
  @spec create(Scope.t(), map()) :: {:ok, Project.t()} | {:error, error()}
  def create(%Scope{workspace: %Workspace{}} = scope, attrs) do
    Workspaces.write_transaction(scope, :create_project, fn scope ->
      %Project{workspace_id: scope.workspace.id}
      |> Project.create_changeset(attrs)
      |> Repo.insert()
      |> notify()
    end)
  end

  ## Reading

  @doc "Gets a project of the scope's workspace by key, in any case."
  @spec get(Scope.t(), String.t()) :: {:ok, Project.t()} | {:error, :forbidden | :not_found}
  def get(%Scope{workspace: %Workspace{id: workspace_id}} = scope, key) when is_binary(key) do
    with :ok <- Policy.authorize(scope, :read_tasks) do
      case Repo.one(by_key(workspace_id, key)) do
        nil -> {:error, :not_found}
        project -> {:ok, put_github(project)}
      end
    end
  end

  @doc """
  Lists the workspace's projects ordered by key. `task_seq` is each
  project's task count.

  ## Options

    * `:include_archived` - also list archived projects (default `false`)
  """
  @spec list(Scope.t(), keyword()) :: {:ok, [Project.t()]} | {:error, :forbidden}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_tasks) do
      query = from(p in Project, where: p.workspace_id == ^workspace_id, order_by: p.key)

      query =
        if Keyword.get(opts, :include_archived, false),
          do: query,
          else: where(query, [p], is_nil(p.archived_at))

      {:ok, query |> Repo.all() |> put_github()}
    end
  end

  @doc """
  Returns the project of `workspace_id` with `key` (any case), or nil. For
  domain code that has already authorized the caller.
  """
  @spec fetch_by_key(pos_integer(), String.t()) :: Project.t() | nil
  def fetch_by_key(workspace_id, key) when is_binary(key), do: Repo.one(by_key(workspace_id, key))

  defp by_key(workspace_id, key),
    do:
      from(p in Project, where: p.workspace_id == ^workspace_id and p.key == ^String.upcase(key))

  ## Changing

  @doc """
  Changes a project's name and description (`:update_project`). A `key` in
  `attrs` is ignored: keys never change.
  """
  @spec update(Scope.t(), String.t(), map()) :: {:ok, Project.t()} | {:error, error()}
  def update(%Scope{workspace: %Workspace{}} = scope, key, attrs) when is_binary(key) do
    Workspaces.write_transaction(scope, :update_project, fn scope ->
      with {:ok, project} <- lock_project(scope, key) do
        project |> Project.update_changeset(attrs) |> save()
      end
    end)
  end

  @doc """
  Archives a project (`:archive_project`): it leaves the default list and
  takes no new tasks; its tasks stay readable and editable. Archiving an
  archived project changes nothing.
  """
  @spec archive(Scope.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def archive(%Scope{} = scope, key), do: set_archived(scope, key, true)

  @doc """
  Restores an archived project (`:archive_project`). Task numbers continue
  from the highest one handed out.
  """
  @spec unarchive(Scope.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def unarchive(%Scope{} = scope, key), do: set_archived(scope, key, false)

  defp set_archived(%Scope{workspace: %Workspace{}} = scope, key, archived?)
       when is_binary(key) do
    Workspaces.write_transaction(scope, :archive_project, fn scope ->
      with {:ok, project} <- lock_project(scope, key) do
        project |> Ecto.Changeset.change(archived_at: archived_at(project, archived?)) |> save()
      end
    end)
  end

  # Archiving again keeps the original time.
  defp archived_at(%Project{archived_at: archived_at}, true),
    do: archived_at || DateTime.utc_now(:second)

  defp archived_at(_project, false), do: nil

  # Waits for task creations holding the row (they allocate a number under
  # its lock), so archiving commits only after them.
  defp lock_project(scope, key) do
    case scope.workspace.id |> by_key(key) |> lock("FOR UPDATE") |> Repo.one() do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  ## GitHub settings

  @github_keys ~w(repository_id base_branch merge_policy merge_method require_ci
                  delete_branch_after_merge)a

  @doc """
  Changes a project's repository binding and merge settings
  (`:manage_github`, designs/15 §2, §4). `attrs` may hold `repository_id`
  (nil unbinds), `base_branch` (nil or "" = the repository's default
  branch), `merge_policy`, `merge_method`, `require_ci` and
  `delete_branch_after_merge`. Archived projects may be changed too.

  A base branch is first checked on GitHub, outside the transaction. The
  transaction then recomputes the repository / base branch pair from the
  locked row: if someone changed it since the check, the check runs once
  more on the new pair, and a second change returns `{:error, :stale}`. The
  repository's availability is decided inside the transaction with its
  installation and repository rows locked `FOR SHARE`.

  Errors: `:not_found` (project or repository), `:repository_unavailable`,
  `:repository_required` (a base branch without a repository),
  `{:branch_not_found, branch}`, `{:github_unavailable, _}`,
  `{:rate_limited, _}`, `:stale`, a changeset.
  """
  @spec update_github_settings(Scope.t(), String.t(), map()) ::
          {:ok, Project.t()} | {:error, error() | {atom(), term()}}
  def update_github_settings(%Scope{workspace: %Workspace{}} = scope, key, attrs)
      when is_binary(key) and is_map(attrs) do
    with :ok <- Policy.authorize(scope, :manage_github),
         {:ok, attrs} <- github_attrs(attrs) do
      settle_github_settings(scope, key, attrs, 2)
    end
  end

  defp github_attrs(attrs) do
    Enum.reduce_while(@github_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case github_attr(key, fetch_attr(attrs, key)) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, invalid_attr(key)}}
      end
    end)
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp github_attr(_key, :error), do: :absent
  defp github_attr(key, {:ok, value}), do: github_attr(key, value)

  defp github_attr(:repository_id, value) when is_integer(value) or is_nil(value),
    do: {:ok, value}

  defp github_attr(:repository_id, ""), do: {:ok, nil}

  defp github_attr(:repository_id, value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp github_attr(:repository_id, _value), do: :error
  defp github_attr(:base_branch, value) when value in [nil, ""], do: {:ok, nil}
  defp github_attr(:base_branch, value) when is_binary(value), do: {:ok, value}
  defp github_attr(:base_branch, _value), do: :error
  defp github_attr(_key, value), do: {:ok, value}

  defp invalid_attr(key) do
    %Project{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(key, "is invalid")
  end

  defp settle_github_settings(scope, key, attrs, attempts_left) do
    with {:ok, project} <- fetch_project(scope.workspace.id, key),
         {:ok, pair} <- github_pair(project, attrs),
         :ok <- check_pair(scope.workspace.id, pair) do
      result =
        Workspaces.write_transaction(scope, :manage_github, fn scope ->
          save_github_settings(scope, key, attrs, pair)
        end)

      case result do
        {:error, :pair_changed} when attempts_left > 1 ->
          settle_github_settings(scope, key, attrs, attempts_left - 1)

        {:error, :pair_changed} ->
          {:error, :stale}

        {:ok, project} ->
          {:ok, put_github(project)}

        error ->
          error
      end
    end
  end

  defp fetch_project(workspace_id, key) do
    case Repo.one(by_key(workspace_id, key)) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  # The repository / base branch pair the save would leave: no repository
  # means no base branch.
  defp github_pair(project, attrs) do
    repository_id = Map.get(attrs, :repository_id, project.repository_id)

    case {repository_id, Map.get(attrs, :base_branch, project.base_branch)} do
      {nil, branch} when branch != nil ->
        if Map.has_key?(attrs, :base_branch),
          do: {:error, :repository_required},
          else: {:ok, {nil, nil}}

      pair ->
        {:ok, pair}
    end
  end

  defp check_pair(_workspace_id, {nil, nil}), do: :ok

  defp check_pair(workspace_id, {repository_id, branch}) do
    with {:ok, {repository, installation}} <-
           Repositories.fetch_available(workspace_id, repository_id) do
      check_branch(repository, installation, branch)
    end
  end

  defp check_branch(_repository, _installation, nil), do: :ok

  defp check_branch(repository, installation, branch) do
    case Repositories.branch_exists?(repository, installation, branch) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:branch_not_found, branch}}
      {:error, _reason} = error -> error
    end
  end

  defp save_github_settings(scope, key, attrs, checked_pair) do
    with {:ok, project} <- lock_project(scope, key),
         {:ok, pair} <- github_pair(project, attrs),
         :ok <- same_pair(pair, checked_pair),
         :ok <- lock_available_repository(scope.workspace.id, pair) do
      {repository_id, branch} = pair

      project
      |> Project.github_settings_changeset(attrs, %{
        repository_id: repository_id,
        base_branch: branch
      })
      |> save()
    end
  end

  defp same_pair(pair, pair), do: :ok
  defp same_pair(_pair, _checked), do: {:error, :pair_changed}

  # Installation row, then repository row, both FOR SHARE (lock order of
  # the GitHub writes): syncs, disconnects and refreshes wait for the save.
  defp lock_available_repository(_workspace_id, {nil, _branch}), do: :ok

  defp lock_available_repository(workspace_id, {repository_id, _branch}) do
    installation_id =
      Repo.one(
        from(r in Repository,
          where: r.workspace_id == ^workspace_id and r.id == ^repository_id,
          select: r.installation_id
        )
      )

    case installation_id do
      nil -> {:error, :not_found}
      installation_id -> lock_repository(installation_id, repository_id)
    end
  end

  defp lock_repository(installation_id, repository_id) do
    installation =
      Repo.one!(from(i in Installation, where: i.id == ^installation_id, lock: "FOR SHARE"))

    repository =
      Repo.one!(from(r in Repository, where: r.id == ^repository_id, lock: "FOR SHARE"))

    cond do
      # A sync moved the repository to another installation meanwhile.
      repository.installation_id != installation.id -> {:error, :pair_changed}
      Repositories.available?(repository, installation) -> :ok
      true -> {:error, :repository_unavailable}
    end
  end

  # Puts the virtual `repository` and `effective_base_branch` fields.
  defp put_github(projects) when is_list(projects) do
    ids = for %Project{repository_id: id} <- projects, id != nil, uniq: true, do: id

    repositories =
      if ids == [] do
        %{}
      else
        from(r in Repository,
          join: i in Installation,
          on: i.id == r.installation_id,
          where: r.id in ^ids,
          select: {r, i}
        )
        |> Repo.all()
        |> Map.new(fn {r, i} -> {r.id, {r, i}} end)
      end

    Enum.map(projects, &put_repository(&1, Map.get(repositories, &1.repository_id)))
  end

  defp put_github(%Project{} = project), do: hd(put_github([project]))

  defp put_repository(project, nil),
    do: %{project | repository: nil, effective_base_branch: nil}

  defp put_repository(project, {repository, installation}) do
    %{
      project
      | repository: %{
          id: repository.id,
          owner: repository.owner,
          name: repository.name,
          full_name: Repository.full_name(repository),
          available: Repositories.available?(repository, installation)
        },
        effective_base_branch: project.base_branch || repository.default_branch
    }
  end

  defp save(%Ecto.Changeset{valid?: true, changes: changes} = changeset) when changes == %{},
    do: {:ok, changeset.data}

  defp save(changeset), do: changeset |> Repo.update() |> notify()

  defp notify({:ok, project} = result) do
    Events.after_commit(Events.topic(:workspace, project.workspace_id), {:projects_changed})
    result
  end

  defp notify(error), do: error
end

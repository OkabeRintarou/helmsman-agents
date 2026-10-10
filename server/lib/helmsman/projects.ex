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
        project -> {:ok, project}
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

      {:ok, Repo.all(query)}
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

  defp save(%Ecto.Changeset{valid?: true, changes: changes} = changeset) when changes == %{},
    do: {:ok, changeset.data}

  defp save(changeset), do: changeset |> Repo.update() |> notify()

  defp notify({:ok, project} = result) do
    Events.after_commit(Events.topic(:workspace, project.workspace_id), {:projects_changed})
    result
  end

  defp notify(error), do: error
end

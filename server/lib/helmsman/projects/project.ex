defmodule Helmsman.Projects.Project do
  @moduledoc """
  A project: the unit that groups a workspace's tasks (designs/04 §1).

  The key prefixes every task ID, so it never changes after creation and,
  as projects are never deleted, is never reused. `task_seq` is the highest
  task number handed out, which is also the project's task count.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @key_format ~r/\A[A-Z][A-Z0-9]{1,9}\z/
  @key_message "must be 2-10 characters of A-Z and 0-9, starting with a letter"
  @max_description_bytes 65_536

  schema "projects" do
    belongs_to :workspace, Workspace
    field :key, :string
    field :name, :string
    field :description, :string, default: ""
    field :task_seq, :integer, default: 0
    field :archived_at, :utc_datetime

    # GitHub settings (designs/15 §2, §4). `repository_id` references a
    # repository of the same workspace (composite foreign key); a nil
    # `base_branch` means the repository's default branch.
    field :repository_id, :id
    field :base_branch, :string
    field :merge_policy, :string, default: "on_verified"
    field :merge_method, :string, default: "squash"
    field :require_ci, :boolean, default: true
    field :delete_branch_after_merge, :boolean, default: true

    # Local repository mode (`add-local-repositories` decision 5): at most
    # one of `repository_id` and `local_repository_id` is set.
    field :local_repository_id, :id

    # Set by `Helmsman.Projects` reads: `%{owner, name, full_name, available}`
    # or nil, and the effective base branch (the default branch when
    # `base_branch` is nil).
    field :repository, :map, virtual: true
    # `%{id, name, daemon_id, daemon_name, owner, status, unavailable_reason,
    # path}` or nil; `path` is nil unless the reader may see it.
    field :local_repository, :map, virtual: true
    field :effective_base_branch, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @merge_policies ~w(on_verified on_verified_human manual)
  @merge_methods ~w(squash merge rebase)

  @doc "The merge policies."
  @spec merge_policies() :: [String.t()]
  def merge_policies, do: @merge_policies

  @doc "The merge methods."
  @spec merge_methods() :: [String.t()]
  def merge_methods, do: @merge_methods

  @doc """
  Changeset for the GitHub settings. `repository_id` and `base_branch` are
  put by `Helmsman.Projects.update_github_settings/3` after checking them;
  only the merge settings are cast here.
  """
  @spec github_settings_changeset(t(), map(), map()) :: Ecto.Changeset.t()
  def github_settings_changeset(project, attrs, %{
        repository_id: repository_id,
        base_branch: branch
      }) do
    project
    |> cast(attrs, [:merge_policy, :merge_method, :require_ci, :delete_branch_after_merge])
    |> put_change(:repository_id, repository_id)
    |> put_change(:base_branch, branch)
    |> validate_required([:merge_policy, :merge_method, :require_ci, :delete_branch_after_merge])
    |> validate_inclusion(:merge_policy, @merge_policies)
    |> validate_inclusion(:merge_method, @merge_methods)
    |> validate_length(:base_branch, min: 1, max: 255, count: :codepoints)
    |> check_constraint(:merge_policy, name: :projects_merge_policy_check, message: "is invalid")
    |> check_constraint(:merge_method, name: :projects_merge_method_check, message: "is invalid")
    |> check_constraint(:base_branch,
      name: :projects_base_branch_length,
      message: "must be 1-255 characters"
    )
  end

  @doc """
  Changeset for a local repository binding
  (`Helmsman.Projects.bind_local_repository/4`): the repository and, when
  `opts` has `:base_branch`, the base branch (nil or `""` = the
  repository's default branch). Unbinding clears the base branch and
  ignores `:base_branch` (`add-local-repositories` decision 18).
  """
  @spec local_binding_changeset(t(), pos_integer() | nil, keyword()) :: Ecto.Changeset.t()
  def local_binding_changeset(project, nil, _opts),
    do: change(project, local_repository_id: nil, base_branch: nil)

  def local_binding_changeset(project, local_repository_id, opts) do
    changeset = change(project, local_repository_id: local_repository_id)

    case Keyword.fetch(opts, :base_branch) do
      :error -> changeset
      {:ok, branch} when branch in [nil, ""] -> put_change(changeset, :base_branch, nil)
      {:ok, branch} when is_binary(branch) -> put_base_branch(changeset, branch)
      {:ok, _other} -> add_error(changeset, :base_branch, "is invalid")
    end
  end

  defp put_base_branch(changeset, branch) do
    changeset
    |> put_change(:base_branch, branch)
    |> validate_length(:base_branch, min: 1, max: 255, count: :codepoints)
    |> check_constraint(:base_branch,
      name: :projects_base_branch_length,
      message: "must be 1-255 characters"
    )
  end

  @doc """
  Changeset for a new project. The key is upcased and the name trimmed
  before validation; `workspace_id` is set by the caller.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:key, :name, :description], empty_values: [])
    |> update_change(:key, &normalize(&1, :upcase))
    |> validate_required([:workspace_id, :key])
    |> validate_format(:key, @key_format, message: @key_message)
    |> validate_fields()
    |> unique_constraint(:key,
      name: :projects_workspace_id_key_index,
      message: "has already been taken"
    )
    |> check_constraint(:key, name: :projects_key_format, message: @key_message)
  end

  @doc "Changeset for changing the name and description; the key is ignored."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description], empty_values: [])
    |> validate_fields()
  end

  defp validate_fields(changeset) do
    changeset
    |> update_change(:name, &normalize(&1, :trim))
    |> update_change(:description, &normalize(&1, :nil_to_empty))
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_length(:description, max: @max_description_bytes, count: :bytes)
    |> check_constraint(:name, name: :projects_name_length, message: "must be 1-80 characters")
    |> check_constraint(:description,
      name: :projects_description_size,
      message: "must be at most 64 KB"
    )
  end

  defp normalize(value, :upcase) when is_binary(value), do: String.upcase(value)
  defp normalize(value, :trim) when is_binary(value), do: String.trim(value)
  defp normalize(nil, :nil_to_empty), do: ""
  defp normalize(value, _), do: value
end

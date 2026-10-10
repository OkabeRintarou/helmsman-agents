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

    timestamps(type: :utc_datetime)
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

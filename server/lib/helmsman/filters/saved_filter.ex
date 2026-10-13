defmodule Helmsman.Filters.SavedFilter do
  @moduledoc "A user-owned private or shared BQL query."
  use Ecto.Schema
  import Ecto.Changeset
  alias Helmsman.BQL
  @type t :: %__MODULE__{}
  schema "saved_filters" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :owner, Helmsman.Accounts.User
    field :name, :string
    field :bql, :string
    field :visibility, Ecto.Enum, values: [:private, :workspace], default: :private
    field :lock_version, :integer, default: 1
    field :valid_bql, :boolean, virtual: true, default: true
    field :bql_error, :map, virtual: true
    field :owner_left, :boolean, virtual: true, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:name, :bql, :visibility], empty_values: [])
    |> update_change(:name, &trim_name/1)
    |> validate_required([:name, :bql])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> validate_length(:bql, max: 2000, count: :codepoints)
    |> validate_bql()
    |> unique_constraint(:name, name: :saved_filters_workspace_id_owner_id_name_index)
    |> check_constraint(:name, name: :saved_filters_name_length)
    |> check_constraint(:bql, name: :saved_filters_bql_length)
    |> check_constraint(:visibility, name: :saved_filters_visibility_check)
  end

  defp trim_name(name) when is_binary(name), do: String.trim(name)
  defp trim_name(name), do: name

  defp validate_bql(changeset) do
    if changeset.valid? do
      case BQL.parse(get_field(changeset, :bql)) do
        {:ok, _} ->
          changeset

        {:error, {:invalid_bql, error}} ->
          add_error(changeset, :bql, "#{error.message} (position #{error.position})",
            position: error.position
          )
      end
    else
      changeset
    end
  end
end

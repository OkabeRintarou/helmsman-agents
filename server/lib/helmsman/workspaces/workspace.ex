defmodule Helmsman.Workspaces.Workspace do
  @moduledoc """
  A workspace: the unit that owns and isolates all business data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @slug_format ~r/^[a-z0-9][a-z0-9-]{1,38}$/
  @slug_message "must be 2-39 characters of a-z, 0-9 and -, starting with a letter or digit"

  schema "workspaces" do
    field :slug, :string
    field :name, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a workspace or changing its name and slug.

  The slug is downcased and the name trimmed before validation.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    # Keep blank input as a change so that it fails validation instead of
    # being dropped as "no change".
    |> cast(attrs, [:slug, :name], empty_values: [])
    |> update_change(:slug, &normalize(&1, :downcase))
    |> update_change(:name, &normalize(&1, :trim))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_format, message: @slug_message)
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:slug, message: "has already been taken")
    |> check_constraint(:slug, name: :workspaces_slug_format, message: @slug_message)
    |> check_constraint(:name, name: :workspaces_name_length, message: "must be 1-80 characters")
  end

  defp normalize(value, :downcase) when is_binary(value), do: String.downcase(value)
  defp normalize(value, :trim) when is_binary(value), do: String.trim(value)
  defp normalize(value, _), do: value
end

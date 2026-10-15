defmodule Helmsman.ViewPrefs.Preference do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @statuses ~w(new in_progress done verified rejected cancelled)
  schema "task_view_prefs" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :user, Helmsman.Accounts.User
    field :view, :string, default: "list"
    field :hidden_columns, {:array, :string}, default: ["rejected", "cancelled"]
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pref, attrs) do
    pref
    |> cast(attrs, [:view, :hidden_columns], empty_values: [])
    |> validate_required([:view])
    |> validate_inclusion(:view, ~w(list board))
    |> validate_subset(:hidden_columns, @statuses)
    |> normalize_hidden()
  end

  defp ordered(values), do: Enum.filter(@statuses, &(&1 in values))

  defp normalize_hidden(changeset) do
    case get_field(changeset, :hidden_columns) do
      values when is_list(values) ->
        if Enum.all?(@statuses, &(&1 in values)),
          do: add_error(changeset, :hidden_columns, "must keep at least one column visible"),
          else: update_change(changeset, :hidden_columns, &ordered/1)

      _ ->
        add_error(changeset, :hidden_columns, "is invalid")
    end
  end
end

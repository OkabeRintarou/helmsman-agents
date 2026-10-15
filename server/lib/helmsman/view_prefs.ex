defmodule Helmsman.ViewPrefs do
  @moduledoc "Per-user workspace task view preferences. Web sessions only, including viewers."
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Repo, Workspaces}
  alias Helmsman.ViewPrefs.Preference

  @default %{view: "list", hidden_columns: ["rejected", "cancelled"]}

  @spec get(Scope.t()) :: {:ok, map()} | {:error, :forbidden}
  def get(scope) do
    with :ok <- authorize(scope) do
      preference =
        Repo.get_by(Preference, workspace_id: scope.workspace.id, user_id: scope.user.id)

      {:ok, if(preference, do: Map.take(preference, [:view, :hidden_columns]), else: @default)}
    end
  end

  @spec put(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(scope, attrs) do
    with :ok <- authorize(scope) do
      changeset = Preference.changeset(%Preference{}, attrs)

      fields =
        for key <- [:view, :hidden_columns],
            Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key)),
            into: %{},
            do: {key, Ecto.Changeset.get_field(changeset, key)}

      updates =
        Map.take(fields, [:view, :hidden_columns])
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Map.to_list()

      changeset =
        Ecto.Changeset.change(changeset, workspace_id: scope.workspace.id, user_id: scope.user.id)

      case Repo.insert(changeset,
             conflict_target: [:workspace_id, :user_id],
             on_conflict: [set: updates],
             returning: true
           ) do
        {:ok, preference} -> {:ok, Map.take(preference, [:view, :hidden_columns])}
        error -> error
      end
    end
  end

  defp authorize(%Scope{
         via: via,
         token: nil,
         run: nil,
         user: %{id: id},
         workspace: %{id: workspace_id}
       })
       when via in [nil, :web] do
    if Workspaces.get_membership(workspace_id, id), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_scope), do: {:error, :forbidden}
end

defmodule HelmsmanWeb.BackupData do
  @moduledoc """
  The data settings page's entry to the export / import / claim domain
  (add-data-settings-ui D2): `Helmsman.Backup` and the claim functions of
  `Helmsman.Actors`, plus the permission checks and topics the page needs.

  Export and import rows are the domain's `ExportRecord` / `ImportRecord` (their
  `counts`, `report` and `errors` have string keys); claims are
  `%{id, actor, user_id, user_name, inserted_at}` (`Actors.list_claims/1`).
  """

  alias Helmsman.{Actors, Backup, Policy}

  @type scope :: Helmsman.Accounts.Scope.t()

  @doc "Whether the scope may perform `action` (the domain's policy actions)."
  def can?(scope, action), do: Policy.authorize(scope, action) == :ok

  @doc "The PubSub topics the page subscribes to (besides the shell's `workspace:<id>`)."
  def topics(%{workspace: %{id: wid}, user: %{id: uid}}),
    do: [Backup.topic(wid, uid), Backup.topic(wid)]

  @doc "Download path of an export (a plain controller route)."
  def download_path(%{workspace: %{slug: slug}}, id), do: "/w/#{slug}/exports/#{id}/download"

  @doc "The import upload limit in bytes."
  def max_bytes, do: Application.fetch_env!(:helmsman, :import_max_bytes)

  defdelegate request_export(scope), to: Backup
  defdelegate list_exports(scope), to: Backup
  defdelegate get_export(scope, id), to: Backup
  defdelegate start_import(scope, path, opts), to: Backup
  defdelegate list_imports(scope), to: Backup
  defdelegate get_import(scope, id), to: Backup
  defdelegate list_claims(scope), to: Actors
  defdelegate request_claim(scope, name), to: Actors
  defdelegate cancel_claim(scope, id), to: Actors
  defdelegate decide_claim(scope, id, decision), to: Actors
  defdelegate claim_for(scope, name, user_id), to: Actors
  defdelegate transfer_agent(scope, name, user_id), to: Actors

  @doc "Names of the workspace's unclaimed human identities, sorted."
  @spec unclaimed(scope) :: {:ok, [String.t()]} | {:error, term()}
  def unclaimed(scope) do
    with {:ok, actors} <- Actors.list(scope),
         do: {:ok, for(a <- actors, a.kind == :human and a.unclaimed, do: a.name)}
  end
end

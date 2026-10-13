defmodule HelmsmanWeb.ExportController do
  use HelmsmanWeb, :controller
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Backup, Workspaces}

  def download(conn, %{"slug" => slug, "id" => id}) do
    user = conn.assigns.current_scope.user

    with {:ok, %{workspace: workspace, membership: membership, actor: actor}} <-
           Workspaces.fetch_for_user(user, slug),
         {id, ""} <- Integer.parse(id),
         scope <- %{
           Scope.put_workspace(Scope.for_user(user), workspace, membership, actor)
           | via: :web
         },
         {:ok, file} <- Backup.export_file(scope, id) do
      conn
      |> put_resp_content_type("application/gzip")
      |> send_download({:file, file.path}, filename: file.filename)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end

defmodule HelmsmanWeb.API.BackupController do
  @moduledoc "Workspace snapshot job requests, status and private downloads."
  use HelmsmanWeb.API.Controller
  alias Helmsman.Backup
  alias HelmsmanWeb.API.BackupAccess
  alias OpenApiSpex.Schema

  def create(conn, _params) do
    ToolAction.guarded(conn, "export_workspace", fn ->
      with {:ok, scope} <- BackupAccess.scope(conn),
           {:ok, record} <- Backup.request_export(scope) do
        ToolAction.data(conn, 202, export_record(record))
      end
    end)
  end

  def show(conn, %{"id" => id}), do: show_record(conn, id, :export)
  def import_status(conn, %{"id" => id}), do: show_record(conn, id, :import)

  defp show_record(conn, id, kind) do
    ToolAction.guarded(conn, "backup_status", fn ->
      with {:ok, scope} <- BackupAccess.scope(conn),
           {:ok, id} <- ToolAction.positive_id(id),
           {:ok, record} <- get_record(scope, id, kind) do
        ToolAction.data(conn, 200, view(record, kind))
      end
    end)
  end

  defp view(record, :export), do: export_record(record)
  defp view(record, :import), do: import_record(record)

  defp get_record(scope, id, :export), do: Backup.get_export(scope, id)
  defp get_record(scope, id, :import), do: Backup.get_import(scope, id)

  def download(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "download_export", fn ->
      with {:ok, scope} <- BackupAccess.scope(conn),
           {:ok, id} <- ToolAction.positive_id(id),
           {:ok, file} <- Backup.export_file(scope, id) do
        Phoenix.Controller.send_download(conn, {:file, file.path},
          filename: file.filename,
          content_type: "application/gzip"
        )
      end
    end)
  end

  def export_record(record),
    do:
      Map.take(record, [
        :id,
        :status,
        :size,
        :sha256,
        :counts,
        :error,
        :expires_at,
        :inserted_at,
        :updated_at
      ])

  def import_record(record),
    do:
      Map.take(record, [
        :id,
        :mode,
        :dry_run,
        :source,
        :file_sha256,
        :file_name,
        :status,
        :report,
        :errors,
        :started_at,
        :finished_at,
        :inserted_at,
        :updated_at
      ])

  def operation(action) do
    {id, response, status} =
      case action do
        :create -> {"export_workspace", Schemas.ExportRecord, 202}
        :show -> {"get_export", Schemas.ExportRecord, 200}
        :import_status -> {"get_import", Schemas.ImportRecord, 200}
        :download -> {"download_export", %Schema{type: :string, format: :binary}, 200}
      end

    BackupAccess.operation(
      id: id,
      summary: id,
      tag: "backups",
      status: status,
      response: response,
      write: action == :create,
      params:
        if(action == :create,
          do: [],
          else: [{:id, :path, %Schema{type: :integer, minimum: 1}, "Backup job ID."}]
        ),
      content_type: if(action == :download, do: "application/gzip"),
      description:
        "Admin or owner only, acting as the token user's human identity; the default agent is ignored. Exports and downloads are visible only to their initiator; imports to workspace administrators.",
      errors: [503]
    )
  end
end

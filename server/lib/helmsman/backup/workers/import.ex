defmodule Helmsman.Backup.Workers.Import do
  @moduledoc "Executes a single import attempt; interrupted imports are settled by Prune."
  use Oban.Worker, queue: :backup, max_attempts: 1
  import Ecto.Query
  alias Helmsman.{Accounts, Repo, Tx, Workspaces}
  alias Helmsman.Accounts.Scope
  alias Helmsman.Backup
  alias Helmsman.Backup.{Files, ImportRecord}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Repo.get(ImportRecord, id) do
      %ImportRecord{status: status} = record when status in [:queued, :running] -> execute(record)
      _ -> :ok
    end
  end

  defp execute(record) do
    user = Accounts.get_user!(record.user_id)
    workspace = Workspaces.get(record.workspace_id)

    {:ok, %{membership: membership, actor: actor}} =
      Workspaces.fetch_for_user(user, workspace.slug)

    scope = %{
      Scope.put_workspace(Scope.for_user(user), workspace, membership, actor)
      | via: :web
    }

    {:ok, path} = Files.path(:imports, record.upload)

    record =
      change_status(record, status: :running, started_at: Backup.now())

    opts = [
      mode: record.mode,
      dry_run: record.dry_run,
      source: record.source,
      rename: record.options["rename"] || %{},
      confirm: record.options["confirm"],
      record: record
    ]

    case Backup.import_file(scope, path, opts) do
      {:ok, _} -> :ok
      {:error, _} -> fail_if_active(record)
    end
  rescue
    _ -> fail_if_active(record)
  end

  defp fail_if_active(record) do
    change_status(
      record,
      [
        status: :failed,
        errors: [%{"reason" => "import_failed"}],
        finished_at: Backup.now(),
        upload: nil
      ],
      true
    )

    :ok
  end

  defp change_status(record, fields, remove_upload? \\ false) do
    {:ok, record} =
      Tx.run(fn ->
        current =
          Repo.one!(from(i in ImportRecord, where: i.id == ^record.id, lock: "FOR UPDATE"))

        if current.status in [:queued, :running] do
          remove_upload(current, remove_upload?)
          current = Repo.update!(Ecto.Changeset.change(current, fields))
          Backup.notify_import(current)
          {:ok, current}
        else
          {:ok, current}
        end
      end)

    record
  end

  defp remove_upload(%ImportRecord{upload: upload}, true) when not is_nil(upload),
    do: Files.remove(:imports, upload)

  defp remove_upload(_record, _remove?), do: :ok
end

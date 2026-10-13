defmodule Helmsman.Backup.Workers.Export do
  @moduledoc "Creates one private snapshot artifact and settles its job record."
  use Oban.Worker, queue: :backup, max_attempts: 1
  import Ecto.Query
  alias Helmsman.Backup
  alias Helmsman.Backup.{ExportRecord, Files}
  alias Helmsman.{Events, Repo, Tx, Workspaces}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Repo.get(ExportRecord, id) do
      %ExportRecord{status: status} = record when status in [:queued, :running] -> execute(record)
      _ -> :ok
    end
  end

  defp execute(record) do
    record = settle(record, %{status: :running})
    if record.status == :running, do: create_snapshot(record), else: :ok
  end

  defp create_snapshot(record) do
    case Files.create(:exports, record.workspace_id) do
      {:ok, file} ->
        File.close(file.io)
        record = settle(record, %{file: file.name})

        try do
          case Backup.export_to_file(Workspaces.get(record.workspace_id), file.path) do
            {:ok, stats} ->
              settled =
                settle(
                  record,
                  Map.merge(stats, %{
                    status: :succeeded,
                    file: file.name,
                    expires_at: DateTime.add(Backup.now(), 24 * 60 * 60)
                  })
                )

              if settled.status != :succeeded, do: Files.remove(:exports, file.name)

              :ok

            {:error, _} ->
              failed(record, file.name)
          end
        rescue
          _ -> failed(record, file.name)
        end

      _ ->
        failed(record, nil)
    end
  end

  defp failed(record, name) do
    if name, do: Files.remove(:exports, name)
    settle(record, %{status: :failed, error: "snapshot export failed"})
    :ok
  end

  defp settle(record, fields) do
    {:ok, record} =
      Tx.run(fn ->
        record = Repo.one!(from(e in ExportRecord, where: e.id == ^record.id, lock: "FOR UPDATE"))

        if record.status in [:queued, :running] do
          record = Repo.update!(Ecto.Changeset.change(record, fields))

          Events.after_commit(
            Backup.topic(record.workspace_id, record.user_id),
            {:export, record.id}
          )

          {:ok, record}
        else
          {:ok, record}
        end
      end)

    record
  end
end

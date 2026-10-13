defmodule Helmsman.Backup.Workers.Prune do
  @moduledoc "Expires private artifacts, settles interrupted jobs and removes old orphan files."
  use Oban.Worker, queue: :backup
  import Ecto.Query
  alias Helmsman.Backup
  alias Helmsman.Backup.{ExportRecord, Files, ImportRecord}
  alias Helmsman.{Repo, Tx}

  @impl Oban.Worker
  def perform(_job) do
    now = Backup.now()

    exports = Repo.all(from(e in ExportRecord, select: e.id))
    test_hook({:prune_candidates, :exports})

    Enum.each(exports, &lock_export(&1, now))

    imports =
      Repo.all(
        from(i in ImportRecord,
          where: i.status in [:queued, :running] and not is_nil(i.upload),
          select: i.id
        )
      )

    test_hook({:prune_candidates, :imports})

    Enum.each(imports, &lock_import(&1, now))

    orphans(
      :exports,
      Repo.all(from(e in ExportRecord, where: not is_nil(e.file), select: e.file)),
      now
    )

    orphans(
      :imports,
      Repo.all(from(i in ImportRecord, where: not is_nil(i.upload), select: i.upload)),
      now
    )

    :ok
  end

  defp lock_export(id, now) do
    Tx.run(fn ->
      record = Repo.one(from(e in ExportRecord, where: e.id == ^id, lock: "FOR UPDATE"))
      if record, do: prune_export(record, now)
      {:ok, :done}
    end)
  end

  defp lock_import(id, now) do
    Tx.run(fn ->
      record = Repo.one(from(i in ImportRecord, where: i.id == ^id, lock: "FOR UPDATE"))
      if record && record.status in [:queued, :running], do: prune_import(record, now)
      {:ok, :done}
    end)
  end

  defp prune_export(record, now) do
    cond do
      expired?(record, now) ->
        if record.file, do: Files.remove(:exports, record.file)
        Repo.delete!(record)

      record.status in [:queued, :running] and
          interrupted?(record.id, "Helmsman.Backup.Workers.Export") ->
        if record.file, do: Files.remove(:exports, record.file)

        Repo.update!(
          Ecto.Changeset.change(record, status: :failed, error: "interrupted", file: nil)
        )

      true ->
        :ok
    end
  end

  defp expired?(record, now) do
    (not is_nil(record.expires_at) and DateTime.compare(record.expires_at, now) != :gt) or
      (record.status == :failed and DateTime.diff(now, record.updated_at) > 24 * 60 * 60)
  end

  defp prune_import(record, now) do
    if interrupted?(record.id, "Helmsman.Backup.Workers.Import") do
      if record.upload, do: Files.remove(:imports, record.upload)

      Tx.run(fn ->
        record =
          Repo.update!(
            Ecto.Changeset.change(record,
              status: :failed,
              errors: [%{"reason" => "interrupted"}],
              upload: nil,
              finished_at: now
            )
          )

        Backup.notify_import(record)
        {:ok, record}
      end)
    end
  end

  defp interrupted?(id, worker),
    do:
      not Repo.exists?(
        from(j in Oban.Job,
          where:
            j.worker == ^worker and j.state in ["available", "scheduled", "executing"] and
              fragment("(?->>'id')::bigint", j.args) == ^id
        )
      )

  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end

  defp orphans(kind, names, now) do
    retained = MapSet.new(names)

    files =
      case File.ls(Files.directory(kind)) do
        {:ok, names} -> names
        _ -> []
      end

    for name <- files do
      with false <- MapSet.member?(retained, name),
           {:ok, path} <- Files.path(kind, name),
           {:ok, stat} <- File.lstat(path, time: :posix),
           true <- stat.type == :regular and DateTime.to_unix(now) - stat.mtime > 60 * 60 do
        File.rm(path)
      end
    end
  end
end

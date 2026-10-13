defmodule Helmsman.Backup do
  @moduledoc "Workspace snapshot jobs and synchronous import/export entry points."
  import Ecto.Query
  require Logger
  alias Helmsman.Accounts.Scope
  alias Helmsman.Backup.{Bosun, Export, ExportRecord, Files, ImportRecord}
  alias Helmsman.Backup.Import.{Read, Validate, Write}
  alias Helmsman.Backup.Workers.Export, as: ExportWorker
  alias Helmsman.Backup.Workers.Import, as: ImportWorker
  alias Helmsman.{Events, Locks, Policy, Repo, Tx, Workspaces}
  alias Helmsman.Workspaces.Membership

  def topic(workspace_id, user_id), do: "workspace:#{workspace_id}:backup:#{user_id}"
  def topic(workspace_id), do: "workspace:#{workspace_id}:backup"

  def notify_import(record) do
    if record.user_id,
      do: Events.after_commit(topic(record.workspace_id, record.user_id), {:import, record.id})

    Events.after_commit(topic(record.workspace_id), {:import, record.id})
  end

  def now, do: (Application.get_env(:helmsman, :backup_clock) || (&DateTime.utc_now/0)).()
  def export_to_file(workspace, path), do: Export.write(workspace, path)

  def request_export(scope) do
    with :ok <- Policy.authorize(scope, :export_workspace), :ok <- Files.ready() do
      Workspaces.write_transaction(scope, :export_workspace, &request_export_locked/1)
    end
  end

  defp request_export_locked(scope) do
    # Serialize job creation without blocking ordinary workspace writes.
    Repo.query!("SELECT id FROM workspaces WHERE id=$1 FOR UPDATE", [scope.workspace.id])

    case Repo.one(
           from(e in ExportRecord,
             where: e.workspace_id == ^scope.workspace.id and e.status in [:queued, :running]
           )
         ) do
      nil ->
        record =
          Repo.insert!(%ExportRecord{
            workspace_id: scope.workspace.id,
            user_id: scope.user.id
          })

        {:ok, _} = %{id: record.id} |> ExportWorker.new() |> Oban.insert()
        Events.after_commit(topic(scope.workspace.id, scope.user.id), {:export, record.id})
        {:ok, record}

      record ->
        {:ok, record}
    end
  end

  def list_exports(scope) do
    with :ok <- Policy.authorize(scope, :export_workspace) do
      {:ok,
       Repo.all(
         from(e in ExportRecord,
           where: e.workspace_id == ^scope.workspace.id and e.user_id == ^scope.user.id,
           order_by: [desc: e.id]
         )
       )}
    end
  end

  def get_export(scope, id) do
    with :ok <- Policy.authorize(scope, :export_workspace),
         %ExportRecord{} = record <-
           Repo.one(
             from(e in ExportRecord,
               where:
                 e.id == ^id and e.workspace_id == ^scope.workspace.id and
                   e.user_id == ^scope.user.id
             )
           ) do
      {:ok, record}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def export_file(scope, id) do
    with {:ok, %ExportRecord{status: :succeeded, file: file, expires_at: expires} = record} <-
           get_export(scope, id),
         true <- download_available?(file, expires),
         {:ok, path} <- Files.path(:exports, file),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      stamp = record.updated_at |> Calendar.strftime("%Y%m%d-%H%M%S")
      {:ok, %{path: path, filename: "#{scope.workspace.slug}-#{stamp}.helmsman.json.gz"}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp download_available?(file, expires) do
    if DateTime.compare(expires, now()) == :gt do
      true
    else
      Files.remove(:exports, file)
      false
    end
  end

  def options(scope, opts) do
    opts = Keyword.merge([mode: :merge, dry_run: false, source: :helmsman, rename: %{}], opts)

    if opts[:mode] not in [:merge, :replace] or opts[:source] not in [:helmsman, :bosun] or
         not is_boolean(opts[:dry_run]) or not is_map(opts[:rename]) or
         (Keyword.has_key?(opts, :file_name) and not is_binary(opts[:file_name])) do
      {:error, :invalid_params}
    else
      with :ok <- Policy.authorize(scope, action(opts)),
           :ok <- confirmation(scope, opts),
           do: {:ok, opts}
    end
  end

  defp confirmation(scope, opts) do
    if opts[:mode] == :replace and opts[:confirm] != scope.workspace.slug,
      do: {:error, :confirmation_required},
      else: :ok
  end

  defp action(opts), do: if(opts[:mode] == :replace, do: :import_replace, else: :import_merge)

  def start_import(scope, path, opts \\ []) do
    with {:ok, opts} <- options(scope, opts), :ok <- Files.ready() do
      Workspaces.write_transaction(scope, action(opts), &start_import_locked(&1, path, opts))
    end
  end

  defp start_import_locked(scope, path, opts) do
    Repo.query!("SELECT id FROM workspaces WHERE id=$1 FOR UPDATE", [scope.workspace.id])

    if busy?(scope.workspace.id) do
      {:error, :busy}
    else
      copy_and_enqueue(scope, path, opts)
    end
  end

  defp copy_and_enqueue(scope, path, opts) do
    with {:ok, upload} <- Files.copy_import(scope.workspace.id, path) do
      try do
        case enqueue_import(scope, path, opts, upload) do
          {:ok, _} = result ->
            result

          error ->
            Files.remove(:imports, upload)
            error
        end
      rescue
        error ->
          Files.remove(:imports, upload)
          reraise error, __STACKTRACE__
      end
    end
  end

  defp enqueue_import(scope, path, opts, upload) do
    record =
      Repo.insert!(%ImportRecord{
        workspace_id: scope.workspace.id,
        user_id: scope.user.id,
        mode: opts[:mode],
        dry_run: opts[:dry_run],
        source: opts[:source],
        file_name: import_file_name(path, opts),
        upload: upload,
        options:
          opts
          |> Keyword.delete(:file_name)
          |> Map.new(fn {k, v} -> {to_string(k), if(is_atom(v), do: to_string(v), else: v)} end)
      })

    with {:ok, _} <- %{id: record.id} |> ImportWorker.new() |> Oban.insert() do
      notify_import(record)
      {:ok, record}
    end
  end

  defp import_file_name(path, opts),
    do: String.slice(Keyword.get(opts, :file_name, Path.basename(path)), 0, 255)

  def busy?(wid),
    do:
      Repo.exists?(
        from(i in ImportRecord, where: i.workspace_id == ^wid and i.status in [:queued, :running])
      )

  def list_imports(scope) do
    with :ok <- Policy.authorize(scope, :view_imports),
         do:
           {:ok,
            Repo.all(
              from(i in ImportRecord,
                where: i.workspace_id == ^scope.workspace.id,
                order_by: [desc: i.id]
              )
            )}
  end

  def get_import(scope, id) do
    with :ok <- Policy.authorize(scope, :view_imports),
         %ImportRecord{} = record <-
           Repo.one(
             from(i in ImportRecord, where: i.id == ^id and i.workspace_id == ^scope.workspace.id)
           ) do
      {:ok, record}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def import_file(%Scope{} = scope, path, opts \\ []) do
    with {:ok, opts} <- options(scope, opts),
         {:ok, record} <- reserve_import(scope, path, opts) do
      hash = file_hash(path)
      result = safely_import(fn -> read_and_write(scope, path, opts, record.id, hash) end)
      finish_import(record, result, hash)
      result
    end
  end

  defp reserve_import(scope, path, opts) do
    case opts[:record] do
      %ImportRecord{workspace_id: wid, user_id: uid} = record
      when wid == scope.workspace.id and uid == scope.user.id ->
        {:ok, record}

      %ImportRecord{} ->
        {:error, :not_found}

      _ ->
        reserve_sync_import(scope, path, opts)
    end
  end

  defp reserve_sync_import(scope, path, opts) do
    Workspaces.write_transaction(scope, action(opts), fn scope ->
      Repo.query!("SELECT id FROM workspaces WHERE id=$1 FOR UPDATE", [scope.workspace.id])

      if busy?(scope.workspace.id) do
        {:error, :busy}
      else
        record =
          Repo.insert!(%ImportRecord{
            workspace_id: scope.workspace.id,
            user_id: scope.user.id,
            mode: opts[:mode],
            dry_run: opts[:dry_run],
            source: opts[:source],
            file_name: import_file_name(path, opts),
            status: :running,
            started_at: now()
          })

        notify_import(record)
        {:ok, record}
      end
    end)
  end

  defp safely_import(fun) do
    fun.()
  rescue
    error ->
      Logger.error("backup import failed: #{inspect(error.__struct__)}")
      {:error, :import_failed}
  end

  defp file_hash(path) do
    File.stream!(path, 64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  defp read_and_write(scope, path, opts, id, hash) do
    rename =
      if opts[:source] == :bosun, do: Map.delete(opts[:rename], "user"), else: opts[:rename]

    with {:ok, data} <- Read.file(path),
         {:ok, data} <- convert(data, scope, opts),
         {:ok, data} <- Validate.validate(data, rename) do
      write(scope, data, Keyword.put(opts, :rename, rename), id, hash)
    end
  end

  defp convert(data, scope, opts) do
    if opts[:source] == :helmsman,
      do: {:ok, data},
      else: Bosun.convert(data, scope.actor.name, opts[:rename])
  end

  defp write(scope, data, opts, id, hash) do
    result =
      Tx.run(
        fn ->
          Repo.query!("SET LOCAL lock_timeout = '30s'")
          Locks.maint_exclusive!(scope.workspace.id, timeout: 35_000)
          test_hook(:import_locked)
          write_locked(scope, data, opts, id, hash)
        end,
        timeout: :timer.minutes(30)
      )

    case result do
      {:error, {:dry_run, report}} -> {:ok, report}
      result -> result
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :lock_not_available,
        do: {:error, :busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp write_locked(scope, data, opts, id, hash) do
    case Repo.one(
           from(m in Membership,
             where: m.workspace_id == ^scope.workspace.id and m.user_id == ^scope.user.id,
             lock: "FOR SHARE"
           )
         ) do
      nil ->
        {:error, :not_found}

      member ->
        scope = %{scope | role: member.role}

        write_authorized(scope, data, opts, id, hash)
    end
  end

  defp write_authorized(scope, data, opts, id, hash) do
    with :ok <- Policy.authorize(scope, action(opts)),
         %ImportRecord{status: status} = record <-
           Repo.one(from(i in ImportRecord, where: i.id == ^id, lock: "FOR UPDATE")),
         true <- status in [:queued, :running],
         {:ok, report} <- Write.run(scope, data, opts) do
      if opts[:dry_run] do
        Repo.rollback({:dry_run, report})
      else
        settle_import(record, {:ok, report}, hash)
        test_hook(:import_audited)

        Events.after_commit(
          Events.topic(:workspace, scope.workspace.id),
          {:workspace_imported, id}
        )

        {:ok, report}
      end
    else
      false -> {:error, :interrupted}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp finish_import(record, result, hash) do
    # A real successful import settles its audit in the data transaction.
    # Dry runs and failures settle separately because that transaction rolled back.
    Tx.run(fn ->
      current = Repo.one!(from(i in ImportRecord, where: i.id == ^record.id, lock: "FOR UPDATE"))
      if current.status in [:queued, :running], do: settle_import(current, result, hash)
      {:ok, :done}
    end)

    if record.upload, do: Files.remove(:imports, record.upload)
  end

  defp settle_import(record, result, hash) do
    fields =
      case result do
        {:ok, report} -> %{status: :succeeded, report: json(report), errors: []}
        {:error, reason} -> %{status: :failed, errors: errors(reason)}
      end

    record =
      Repo.update!(
        Ecto.Changeset.change(
          record,
          Map.merge(fields, %{file_sha256: hash, finished_at: now(), upload: nil})
        )
      )

    notify_import(record)
    record
  end

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

  def json(value), do: value |> Jason.encode!() |> Jason.decode!()
  def errors({:invalid_import, errors}), do: json(errors)
  def errors({reason, detail}), do: [%{"reason" => to_string(reason), "detail" => json(detail)}]
  def errors(reason), do: [%{"reason" => to_string(reason)}]
end

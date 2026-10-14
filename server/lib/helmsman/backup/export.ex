defmodule Helmsman.Backup.Export do
  @moduledoc "Streams a consistent read-only snapshot directly into a gzip artifact."
  import Ecto.Query
  alias Helmsman.Actors.Actor
  alias Helmsman.Backup.Format
  alias Helmsman.Feedback.Entry
  alias Helmsman.Filters.SavedFilter
  alias Helmsman.Links.Link
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Tasks.{Task, TaskEvent}

  def write(workspace, path) do
    with {:ok, io} <- File.open(path, [:write, :binary]),
         :ok <- File.chmod(path, 0o600) do
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

      try do
        result =
          Repo.transact(
            fn ->
              set_isolation()

              header = %{
                "format" => "helmsman-export",
                "version" => 1,
                "exported_at" => Format.time(DateTime.utc_now()),
                "source" => %{
                  "host" =>
                    URI.parse(Application.get_env(:helmsman, :public_url, "http://localhost")).host,
                  "app_version" => to_string(Application.spec(:helmsman, :vsn))
                },
                "workspace" => %{"slug" => workspace.slug, "name" => workspace.name}
              }

              keys = Enum.sort(Map.keys(header) ++ Format.collections())
              put(io, z, "{")

              counts =
                Enum.reduce(Enum.with_index(keys), %{}, fn {key, index}, counts ->
                  if index > 0, do: put(io, z, ",")
                  put(io, z, [Format.encode(key), ":"])

                  if key in Format.collections() do
                    put(io, z, "[")

                    count =
                      query(key, workspace.id)
                      |> Repo.stream(max_rows: 500)
                      |> Enum.reduce(0, fn row, n ->
                        if n > 0, do: put(io, z, ",")
                        put(io, z, Format.encode_iodata(row))
                        if rem(n + 1, 500) == 0, do: test_hook({:export_batch, key, n + 1})
                        n + 1
                      end)

                    put(io, z, "]")
                    test_hook({:export_read, key})
                    Map.put(counts, key, count)
                  else
                    put(io, z, Format.encode_iodata(header[key]))
                    counts
                  end
                end)

              put(io, z, "}")
              :ok = IO.binwrite(io, :zlib.deflate(z, <<>>, :finish))
              {:ok, counts}
            end,
            timeout: :timer.minutes(30)
          )

        File.close(io)

        with {:ok, counts} <- result do
          hash =
            File.stream!(path, 64 * 1024)
            |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

          {:ok,
           %{
             counts: counts,
             size: File.stat!(path).size,
             sha256: Base.encode16(:crypto.hash_final(hash), case: :lower)
           }}
        end
      rescue
        error ->
          File.rm(path)
          reraise error, __STACKTRACE__
      after
        File.close(io)
        :zlib.close(z)
      end
    end
  end

  if Mix.env() == :test do
    defp set_isolation do
      unless Application.get_env(:helmsman, :backup_sandbox, false),
        do: Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
    end
  else
    defp set_isolation,
      do: Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
  end

  defp put(io, z, data) do
    :ok = IO.binwrite(io, :zlib.deflate(z, IO.iodata_to_binary(data)))
  end

  def query("actors", wid) do
    from(a in Actor,
      left_join: owner in Actor,
      on:
        owner.workspace_id == a.workspace_id and owner.user_id == a.owner_id and
          owner.kind == :human,
      where: a.workspace_id == ^wid,
      order_by: a.name,
      select: %{
        "name" => a.name,
        "kind" => a.kind,
        "disabled" => not is_nil(a.disabled_at),
        "owner" => owner.name
      }
    )
  end

  def query("projects", wid) do
    from(p in Project,
      where: p.workspace_id == ^wid,
      order_by: p.key,
      select: %{
        "key" => p.key,
        "name" => p.name,
        "description" => p.description,
        "task_seq" => p.task_seq,
        "archived_at" =>
          fragment(
            ~s|to_char(? AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')|,
            p.archived_at
          ),
        "created_at" => fragment(~s|to_char(?, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')|, p.inserted_at),
        "updated_at" => fragment(~s|to_char(?, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')|, p.updated_at)
      }
    )
  end

  def query("tasks", wid) do
    from(t in Task,
      join: p in Project,
      on: p.id == t.project_id,
      join: a in Actor,
      on: a.id == t.created_by_id,
      left_join: b in Actor,
      on: b.id == t.assignee_id,
      left_join: epic in Task,
      on: epic.id == t.epic_id,
      where: t.workspace_id == ^wid,
      order_by: [p.key, t.seq],
      select: %{
        "id" => t.ident,
        "project" => p.key,
        "seq" => t.seq,
        "title" => t.title,
        "description" => t.description,
        "status" => t.status,
        "priority" => t.priority,
        "kind" => t.kind,
        "labels" => t.labels,
        "epic" => epic.ident,
        "created_by" => a.name,
        "assignee" => b.name,
        "created_at" => t.inserted_at,
        "updated_at" => t.updated_at
      }
    )
  end

  def query("task_events", wid) do
    from(e in TaskEvent,
      join: t in Task,
      on: t.id == e.task_id,
      join: a in Actor,
      on: a.id == e.actor_id,
      left_join: f in Entry,
      on: f.id == e.feedback_id,
      where: e.workspace_id == ^wid,
      order_by: [t.ident, e.inserted_at, e.id],
      select: %{
        "task" => t.ident,
        "n" =>
          fragment(
            "row_number() over (partition by ? order by ?, ?)",
            e.task_id,
            e.inserted_at,
            e.id
          ),
        "from" => e.from_status,
        "to" => e.to_status,
        "actor" => a.name,
        "comment" => e.comment,
        "commits" => e.commits,
        "tests" => e.tests,
        "auto" => e.auto,
        "auto_reason" => e.auto_reason,
        "feedback" =>
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE ? || '#' || ?::text END",
            f.id,
            t.ident,
            f.seq
          ),
        "verified_sha" => e.verified_sha,
        "assignee_side" =>
          fragment(
            "ARRAY(SELECT name::text FROM unnest(?) WITH ORDINALITY x(id, n) JOIN actors a ON a.id = x.id ORDER BY x.n)",
            e.assignee_side_ids
          ),
        "at" => e.inserted_at
      }
    )
  end

  def query("feedback", wid) do
    from(f in Entry,
      join: t in Task,
      on: t.id == f.task_id,
      join: a in Actor,
      on: a.id == f.author_id,
      left_join: prev in Entry,
      on: prev.id == f.supersedes_id,
      left_join: next in Entry,
      on: next.id == f.superseded_by_id,
      where: f.workspace_id == ^wid,
      order_by: [t.ident, f.seq],
      select: %{
        "id" => fragment("? || '#' || ?::text", t.ident, f.seq),
        "thread" => f.thread_seq,
        "reply_to" =>
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE ? || '#' || ?::text END",
            f.reply_to_seq,
            t.ident,
            f.reply_to_seq
          ),
        "reply_root" =>
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE ? || '#' || ?::text END",
            f.reply_root_seq,
            t.ident,
            f.reply_root_seq
          ),
        "author" => a.name,
        "kind" => f.kind,
        "content" => f.content,
        "status" => f.status,
        "supersedes" =>
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE ? || '#' || ?::text END",
            prev.id,
            t.ident,
            prev.seq
          ),
        "superseded_by" =>
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE ? || '#' || ?::text END",
            next.id,
            t.ident,
            next.seq
          ),
        "mentions" =>
          fragment(
            "ARRAY(SELECT name::text FROM unnest(?) WITH ORDINALITY x(id, n) JOIN actors a ON a.id = x.id ORDER BY x.n)",
            f.mentions
          ),
        "fallback" => f.fallback,
        "at" => f.inserted_at
      }
    )
  end

  def query("links", wid) do
    from(l in Link,
      join: t in Task,
      on: t.id == l.from_task_id,
      join: b in Task,
      on: b.id == l.to_task_id,
      join: a in Actor,
      on: a.id == l.actor_id,
      where: l.workspace_id == ^wid,
      order_by: [t.ident, b.ident, l.type],
      select: %{
        "from" => t.ident,
        "to" => b.ident,
        "type" => l.type,
        "actor" => a.name,
        "at" => l.inserted_at
      }
    )
  end

  def query("saved_filters", wid) do
    from(f in SavedFilter,
      join: a in Actor,
      on: a.workspace_id == f.workspace_id and a.user_id == f.owner_id and a.kind == :human,
      where: f.workspace_id == ^wid and f.visibility == :workspace,
      order_by: [a.name, f.name],
      select: %{"name" => f.name, "bql" => f.bql, "owner" => a.name}
    )
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
end

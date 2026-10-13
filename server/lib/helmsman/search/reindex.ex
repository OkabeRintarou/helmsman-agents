defmodule Helmsman.Search.Reindex do
  @moduledoc """
  Rebuilds the search columns (`add-fulltext-search` decision 9): after
  this capability is deployed and after the tokenizer changes
  (`mix helmsman.reindex`, or `bin/helmsman eval
  "Helmsman.Search.Reindex.run([])"` in a release).

  Rows are read in batches by ID and written one statement each, outside
  any transaction: at most one row lock is held at a time, so business
  writes are never blocked for long nor deadlocked. Each write is
  conditional on the indexed content being what was read; a row changed
  in between is left alone (`skipped`): that change already wrote its
  column with the current code. Idempotent.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Repo
  alias Helmsman.Search.Document
  alias Helmsman.Workspaces

  @default_batch 500

  @type counts :: %{
          tasks: non_neg_integer(),
          feedback: non_neg_integer(),
          cleared: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Rebuilds the columns of every task and feedback record, or of one
  workspace's. Returns the rows written: `tasks`, active `feedback`,
  superseded records whose column was `cleared`, and those `skipped`
  because they changed meanwhile.

  ## Options

    * `:workspace` - a workspace slug (raises `ArgumentError` when there
      is none)
    * `:batch` - rows read at a time (default #{@default_batch})
  """
  @spec run(keyword()) :: counts()
  def run(opts \\ []) when is_list(opts) do
    workspace_id = workspace_id(opts[:workspace])
    batch = opts[:batch] || @default_batch
    counts = %{tasks: 0, feedback: 0, cleared: 0, skipped: 0}

    counts
    |> each_batch(:tasks, workspace_id, batch, &task/2)
    |> each_batch(:active, workspace_id, batch, &active/2)
    |> each_batch(:superseded, workspace_id, batch, &superseded/2)
  end

  defp workspace_id(nil), do: nil

  defp workspace_id(slug) when is_binary(slug) do
    case Workspaces.get_by_slug(slug) do
      nil -> raise ArgumentError, "no workspace #{inspect(slug)}"
      workspace -> workspace.id
    end
  end

  defp each_batch(counts, kind, workspace_id, batch, fun) do
    Stream.unfold(0, fn after_id ->
      case read(kind, workspace_id, after_id, batch) do
        [] -> nil
        rows -> {rows, rows |> List.last() |> hd()}
      end
    end)
    |> Stream.flat_map(& &1)
    |> Enum.reduce(counts, fun)
  end

  defp read(:tasks, workspace_id, after_id, batch) do
    query(
      "SELECT id, ident, labels, title, description FROM tasks",
      "",
      workspace_id,
      after_id,
      batch
    )
  end

  defp read(:active, workspace_id, after_id, batch) do
    query("SELECT id, content FROM feedback", "status = 'active'", workspace_id, after_id, batch)
  end

  defp read(:superseded, workspace_id, after_id, batch) do
    query(
      "SELECT id FROM feedback",
      "status = 'superseded' AND search IS NOT NULL",
      workspace_id,
      after_id,
      batch
    )
  end

  defp query(select, condition, workspace_id, after_id, batch) do
    conditions =
      ["id > $1", condition, workspace_id && "workspace_id = $3"]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" AND ")

    params = if workspace_id, do: [after_id, batch, workspace_id], else: [after_id, batch]
    sql = "#{select} WHERE #{conditions} ORDER BY id LIMIT $2"
    Repo.query!(sql, params).rows
  end

  defp task([id, ident, labels, title, description], counts) do
    search =
      Document.task(%{ident: ident, labels: labels, title: title, description: description})

    test_hook({:task_read, id})

    %{num_rows: n} =
      Repo.query!(
        "UPDATE tasks SET search = $1 WHERE id = $2 AND title = $3 " <>
          "AND description IS NOT DISTINCT FROM $4 AND labels = $5",
        [search, id, title, description, labels]
      )

    count(counts, :tasks, n)
  end

  defp active([id, content], counts) do
    %{num_rows: n} =
      Repo.query!(
        "UPDATE feedback SET search = $1 WHERE id = $2 AND status = 'active' AND content = $3",
        [Document.feedback(content), id, content]
      )

    count(counts, :feedback, n)
  end

  defp superseded([id], counts) do
    %{num_rows: n} =
      Repo.query!(
        "UPDATE feedback SET search = NULL " <>
          "WHERE id = $1 AND status = 'superseded' AND search IS NOT NULL",
        [id]
      )

    # Already cleared by a revision's own statement: nothing to count.
    if n == 1, do: count(counts, :cleared, 1), else: counts
  end

  defp count(counts, key, 1), do: Map.update!(counts, key, &(&1 + 1))
  defp count(counts, _key, 0), do: Map.update!(counts, :skipped, &(&1 + 1))

  # Fault injection for the concurrency tests: compiled in the test
  # environment only.
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

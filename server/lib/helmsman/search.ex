defmodule Helmsman.Search do
  @moduledoc """
  Full-text search over tasks and their active feedback
  (`add-fulltext-search`, designs/10 §1), in Chinese and English, without
  database extensions: terms come from `Helmsman.Search.Tokenizer`, the
  search columns are written with the business data
  (`Helmsman.Search.Document`) and snippets are made here
  (`Helmsman.Search.Snippet`).

  Rebuild the columns with `mix helmsman.reindex`
  (`Helmsman.Search.Reindex`).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback.{Entry, Id}
  alias Helmsman.Policy
  alias Helmsman.Projects
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Search.{Query, Snippet}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Workspaces.Workspace

  @default_limit 20
  @max_limit 50

  @type hit :: %{
          task: Tasks.summary(),
          rank: float(),
          snippet: Snippet.segments() | nil,
          feedback:
            nil
            | %{
                id: String.t(),
                author: %{name: String.t(), kind: String.t()},
                kind: String.t(),
                snippet: Snippet.segments() | nil
              }
        }

  @doc """
  Searches the tasks of the scope's workspace (`:read_tasks`): a task
  matches when the task itself (ID, labels, title, description) or one of
  its active feedback records does. Best first (by `ts_rank_cd`, the
  better of the task and its best record; then most recently updated); a
  query that is the ID of an existing task puts it first.

  ## Options

    * `:project_key` - only this project (`{:error, :not_found}` when
      there is none)
    * `:limit` - at most this many hits (default #{@default_limit}, at most
      #{@max_limit})

  A blank query gives `{:ok, []}`; a query over #{Query.max_length()}
  characters `{:error, {:invalid_query, :too_long}}`, one that is not a
  string `{:error, {:invalid_query, :not_a_string}}`. The number of
  database queries does not depend on the number of hits.
  """
  @spec search(Scope.t(), term(), keyword()) ::
          {:ok, [hit()]} | {:error, :forbidden | :not_found | Query.error()}
  def search(%Scope{workspace: %Workspace{id: workspace_id}} = scope, query, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, parsed} <- Query.parse(query),
         {:ok, project} <- project(workspace_id, opts[:project_key]) do
      case parsed do
        :blank -> {:ok, []}
        groups -> {:ok, run(workspace_id, project, String.trim(query), groups, limit(opts))}
      end
    end
  end

  @doc """
  The condition "the task, or one of its active feedback records, matches
  `tsquery`" (`Helmsman.Search.Query.to_tsquery/1`) on the task bound as
  `binding` (default `:task`): for `Helmsman.Tasks.list/3` and BQL.
  """
  @spec task_matches(String.t(), atom()) :: Ecto.Query.dynamic_expr()
  def task_matches(tsquery, binding \\ :task) when is_binary(tsquery) and is_atom(binding) do
    dynamic(
      [{^binding, t}],
      fragment("? @@ ?::text::tsquery", t.search, ^tsquery) or
        fragment(
          "EXISTS (SELECT 1 FROM feedback f WHERE f.task_id = ? AND f.status = 'active' AND f.search @@ ?::text::tsquery)",
          t.id,
          ^tsquery
        )
    )
  end

  defp project(_workspace_id, nil), do: {:ok, nil}

  defp project(workspace_id, key) when is_binary(key) do
    case Projects.fetch_by_key(workspace_id, key) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp project(_workspace_id, _key), do: {:error, :not_found}

  defp limit(opts) do
    case opts[:limit] do
      n when is_integer(n) -> n |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  ## Running

  defp run(workspace_id, project, query, groups, limit) do
    direct = direct(workspace_id, project, query)

    ranked =
      case Query.to_tsquery(groups) do
        nil -> []
        tsquery -> ranked(workspace_id, project, tsquery, limit)
      end

    ranked
    |> put_direct(direct, limit)
    |> load(groups)
  end

  # The task whose ID the whole query is, in the workspace (and project).
  defp direct(workspace_id, project, query) do
    case Ident.parse(query) do
      {:ok, ident, _key, _seq} ->
        from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)
        |> in_project(project)
        |> select([t], t.id)
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  defp in_project(query, nil), do: query
  defp in_project(query, %Project{id: id}), do: where(query, [t], t.project_id == ^id)

  # One statement: the tasks that match themselves and, per task, the best
  # active record that matches, fully joined; the source is the record
  # when the task does not match itself or the record ranks higher.
  defp ranked(workspace_id, project, tsquery, limit) do
    {project_condition, params} =
      case project do
        nil -> {"", [tsquery, workspace_id, limit]}
        %Project{id: id} -> {" AND t.project_id = $4", [tsquery, workspace_id, limit, id]}
      end

    sql = """
    WITH q AS (SELECT $1::text::tsquery AS q),
    own AS (
      SELECT t.id AS task_id, ts_rank_cd(t.search, q.q) AS rank
      FROM tasks t CROSS JOIN q
      WHERE t.workspace_id = $2#{project_condition} AND t.search @@ q.q
    ),
    fb AS (
      SELECT DISTINCT ON (f.task_id) f.task_id, f.id, ts_rank_cd(f.search, q.q) AS rank
      FROM feedback f JOIN tasks t ON t.id = f.task_id CROSS JOIN q
      WHERE f.workspace_id = $2 AND t.workspace_id = $2#{project_condition}
        AND f.status = 'active' AND f.search @@ q.q
      ORDER BY f.task_id, rank DESC, f.id DESC
    )
    SELECT t.id,
      GREATEST(COALESCE(own.rank, 0), COALESCE(fb.rank, 0))::float8 AS score,
      CASE WHEN own.task_id IS NULL OR fb.rank > own.rank THEN fb.id END
    FROM own FULL OUTER JOIN fb ON fb.task_id = own.task_id
    JOIN tasks t ON t.id = COALESCE(own.task_id, fb.task_id)
    ORDER BY score DESC, t.updated_at DESC, t.id DESC
    LIMIT $3
    """

    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [task_id, rank, feedback_id] ->
      %{task_id: task_id, rank: rank, feedback_id: feedback_id, matched: true}
    end)
  end

  defp put_direct(ranked, nil, _limit), do: ranked

  defp put_direct(ranked, task_id, limit) do
    {own, rest} = Enum.split_with(ranked, &(&1.task_id == task_id))

    first =
      case own do
        [hit] -> hit
        [] -> %{task_id: task_id, rank: 0.0, feedback_id: nil, matched: false}
      end

    Enum.take([first | rest], limit)
  end

  ## Loading

  # Two queries plus the summary's, whatever the number of hits.
  defp load([], _groups), do: []

  defp load(ranked, groups) do
    task_ids = Enum.map(ranked, & &1.task_id)
    feedback_ids = for %{feedback_id: id} when not is_nil(id) <- ranked, do: id

    tasks =
      from(t in Task, where: t.id in ^task_ids)
      |> Repo.all()
      |> Tasks.load_summaries()
      |> Map.new(&{&1.id, &1})

    feedback =
      from(f in Entry, where: f.id in ^feedback_ids, preload: :author)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(ranked, fn hit ->
      task = Map.fetch!(tasks, hit.task_id)
      entry = hit.feedback_id && Map.fetch!(feedback, hit.feedback_id)

      %{
        task: Tasks.summary(task),
        rank: hit.rank,
        snippet: task_snippet(hit, entry, task, groups),
        feedback: entry && feedback_view(entry, task, groups)
      }
    end)
  end

  defp task_snippet(%{matched: true}, nil, task, groups),
    do: Snippet.build(task.description, groups)

  defp task_snippet(_hit, _entry, _task, _groups), do: nil

  defp feedback_view(%Entry{author: %Actor{} = author} = entry, task, groups) do
    %{
      id: Id.build(task.ident, entry.seq),
      author: %{name: author.name, kind: Atom.to_string(author.kind)},
      kind: Atom.to_string(entry.kind),
      snippet: Snippet.build(entry.content, groups)
    }
  end
end

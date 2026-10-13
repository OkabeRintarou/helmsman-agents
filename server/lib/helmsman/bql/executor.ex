defmodule Helmsman.BQL.Executor do
  @moduledoc "BQL execution, stable pages and request-local statement timeout."
  import Ecto.Query
  alias Helmsman.BQL
  alias Helmsman.BQL.Compiler
  alias Helmsman.{Filters, Links, Policy, Repo}
  alias Helmsman.Filters.SavedFilter
  alias Helmsman.Tasks.Task

  @spec query(Helmsman.Accounts.Scope.t(), term(), keyword(), ([Task.t()] -> [map()])) ::
          {:ok, map()} | {:error, term()}
  def query(scope, input, opts, summarize) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ast} <- parse(scope, input),
         {:ok, limit, offset} <- pagination(opts),
         {:ok, compiled} <- Compiler.compile(ast, scope) do
      query =
        from(t in Task, as: :task, where: t.workspace_id == ^scope.workspace.id)
        |> Compiler.prepare()
        |> where(^compiled.predicate)

      order = actual_order(ast.order, compiled.relevance)
      execute(query, order, compiled.relevance, limit, offset, summarize)
    end
  end

  defp parse(scope, %SavedFilter{id: id}) do
    with {:ok, filter} <- Filters.get(scope, id), do: BQL.parse(filter.bql)
  end

  defp parse(_scope, input) when is_binary(input), do: BQL.parse(input)
  defp parse(_scope, %{where: _, order: _} = ast), do: BQL.validate_ast(ast)
  defp parse(_scope, input), do: BQL.parse(input)

  defp pagination(opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    cond do
      not is_integer(limit) or limit < 1 or limit > 200 -> {:error, {:invalid, :limit}}
      not is_integer(offset) or offset < 0 or offset > 10_000 -> {:error, {:invalid, :offset}}
      true -> {:ok, limit, offset}
    end
  end

  defp actual_order([], []), do: [{:updated, :desc}]
  defp actual_order([], _), do: :relevance
  defp actual_order(order, _), do: order

  defp execute(query, order, relevance, limit, offset, summarize) do
    # A caller-owned transaction (including the SQL sandbox) cannot change
    # its read-only flag after earlier writes. A standalone query owns a
    # read-only transaction; nested calls still issue only SELECT statements.
    nested? = Repo.in_transaction?()

    Repo.transact(fn ->
      if not nested?, do: read_only_transaction()
      %{rows: [[old_timeout]]} = Repo.query!("SHOW statement_timeout")

      timeout =
        Application.get_env(:helmsman, BQL, []) |> Keyword.get(:statement_timeout_ms, 5000)

      Repo.query!("SAVEPOINT bql_query")

      try do
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{timeout}ms"])
        test_hook()
        total = Repo.aggregate(query, :count)

        tasks =
          query
          |> ordered(order, relevance)
          |> limit(^limit)
          |> offset(^offset)
          |> preload([:created_by, :assignee])
          |> select_merge(^%{blocked: Links.unsatisfied_dependency(:task)})
          |> Repo.all()
          |> summarize.()

        Repo.query!("RELEASE SAVEPOINT bql_query")
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", [old_timeout])
        {:ok, %{tasks: tasks, total: total, order: order}}
      rescue
        e in Postgrex.Error ->
          Repo.query!("ROLLBACK TO SAVEPOINT bql_query")
          Repo.query!("RELEASE SAVEPOINT bql_query")

          case e.postgres do
            %{code: :query_canceled} -> {:ok, {:query_error, :query_timeout}}
            _ -> reraise e, __STACKTRACE__
          end
      end
    end)
    |> case do
      {:ok, {:query_error, error}} -> {:error, error}
      result -> result
    end
  end

  defp read_only_transaction do
    meta = Ecto.Adapter.lookup_meta(Repo.get_dynamic_repo())

    unless meta.opts[:pool] == DBConnection.Ownership do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
    end
  end

  if Mix.env() == :test do
    defp test_hook do
      if hook = Process.get(:helmsman_bql_query_hook), do: hook.()
    end
  else
    defp test_hook, do: :ok
  end

  defp ordered(query, :relevance, relevance),
    do: query |> order_by(^[desc: Compiler.score(relevance)]) |> fallback()

  defp ordered(query, fields, _relevance) do
    Enum.reduce(fields, query, fn
      {:id, direction}, query ->
        query
        |> order_by(^[{nulls_last(direction), Compiler.expression(:project)}])
        |> order_by([task: t], [{^direction, t.seq}])

      {field, direction}, query ->
        order_by(query, ^[{nulls_last(direction), Compiler.sort_expression(field)}])
    end)
    |> fallback()
  end

  defp fallback(query), do: order_by(query, [task: t], desc: t.updated_at, desc: t.id)
  defp nulls_last(:asc), do: :asc_nulls_last
  defp nulls_last(:desc), do: :desc_nulls_last
end

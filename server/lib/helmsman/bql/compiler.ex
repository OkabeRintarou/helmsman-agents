defmodule Helmsman.BQL.Compiler do
  @moduledoc "Parameterized SQL predicates with total boolean semantics."
  import Ecto.Query
  alias Helmsman.Actors.Actor
  alias Helmsman.BQL.Fields
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.{Links, Search}
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.Run
  alias Helmsman.Search.Query
  alias Helmsman.Squads.{Member, Squad}
  alias Helmsman.Tasks.Task

  @spec prepare(Ecto.Query.t()) :: Ecto.Query.t()
  def prepare(query) do
    latest_run =
      from(r in Run,
        where:
          r.task_id == parent_as(:task).id and r.workspace_id == parent_as(:task).workspace_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1,
        select: %{status: r.status}
      )

    latest_pr =
      from(p in PullRequest,
        where:
          p.task_id == parent_as(:task).id and p.workspace_id == parent_as(:task).workspace_id,
        order_by: [desc: p.id],
        limit: 1,
        select: %{state: p.state, checks_state: p.checks_state, merge_status: p.merge_status}
      )

    query
    |> join(:inner, [task: t], p in Project,
      on: p.id == t.project_id and p.workspace_id == t.workspace_id,
      as: :project
    )
    |> join(:left, [task: t], a in Actor,
      on: a.id == t.assignee_id and a.workspace_id == t.workspace_id,
      as: :assignee
    )
    |> join(:inner, [task: t], a in Actor,
      on: a.id == t.created_by_id and a.workspace_id == t.workspace_id,
      as: :creator
    )
    |> join(:left, [task: t], e in Task,
      on: e.id == t.epic_id and e.workspace_id == t.workspace_id,
      as: :epic
    )
    |> join(:left_lateral, [], r in subquery(latest_run), on: true, as: :run)
    |> join(:left_lateral, [], p in subquery(latest_pr), on: true, as: :pr)
  end

  @spec compile(map(), Helmsman.Accounts.Scope.t()) :: {:ok, map()} | {:error, term()}
  def compile(ast, scope) do
    {:ok, %{predicate: node(ast.where, scope), relevance: relevance(ast.where)}}
  catch
    {:compile_error, reason} -> {:error, reason}
  end

  defp node(true, _scope), do: dynamic(true)

  defp node({:not, child}, scope) do
    predicate = node(child, scope)
    dynamic(not (^predicate))
  end

  defp node({op, nodes}, scope) when op in [:and, :or] do
    Enum.reduce(nodes, dynamic(^(op == :and)), fn child, acc ->
      predicate = node(child, scope)
      if op == :and, do: dynamic(^acc and ^predicate), else: dynamic(^acc or ^predicate)
    end)
  end

  defp node({:cond, field, op, value}, scope) do
    value = resolve(value, field, scope)
    positive_op = %{neq: :eq, not_in: :in, nmatch: :match, not_empty: :empty}[op] || op
    predicate = positive(field, positive_op, value, scope)
    predicate = dynamic(fragment("COALESCE(?, FALSE)", ^predicate))
    if op in [:neq, :not_in, :nmatch, :not_empty], do: dynamic(not (^predicate)), else: predicate
  end

  defp resolve(values, field, scope) when is_list(values),
    do: Enum.map(values, &resolve(&1, field, scope))

  defp resolve(:current_user, :owner, %{actor: %{kind: kind} = actor}) do
    id = if kind == :human, do: actor.user_id, else: actor.owner_id
    if id, do: {:owner_id, id}, else: throw({:compile_error, :no_identity})
  end

  defp resolve(:current_user, _field, %{actor: %{name: name}}), do: name
  defp resolve(:current_user, _field, _scope), do: throw({:compile_error, :no_identity})
  defp resolve(value, _field, _scope), do: value

  defp positive(:blocked, :eq, value, _scope) do
    predicate = Links.unsatisfied_dependency(:task)
    dynamic(^predicate == ^value)
  end

  defp positive(:labels, :empty, _value, _scope),
    do: dynamic([task: t], fragment("cardinality(?) = 0", t.labels))

  defp positive(:labels, :eq, value, _scope),
    do:
      dynamic(
        [task: t],
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS label WHERE lower(label) = ?)",
          t.labels,
          ^value
        )
      )

  defp positive(:labels, :in, values, _scope),
    do:
      dynamic(
        [task: t],
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS label WHERE lower(label) = ANY(?::text[]))",
          t.labels,
          ^values
        )
      )

  defp positive(:labels, :match, value, _scope),
    do:
      dynamic(
        [task: t],
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS label WHERE label ILIKE ?)",
          t.labels,
          ^pattern(value)
        )
      )

  defp positive(field, op, value, _scope)
       when field in [:depends_on, :blocks, :replaces, :replaced_by], do: link(field, op, value)

  defp positive(:feedback, :empty, _value, _scope),
    do:
      dynamic(
        [task: t],
        not fragment(
          "EXISTS (SELECT 1 FROM feedback f WHERE f.task_id = ? AND f.workspace_id = ? AND f.status = 'active')",
          t.id,
          t.workspace_id
        )
      )

  defp positive(field, :match, value, _scope) when field in [:text, :feedback] do
    case tsquery(value) do
      nil ->
        dynamic(false)

      ts when field == :text ->
        Search.task_matches(ts, :task)

      ts ->
        dynamic(
          [task: t],
          fragment(
            "EXISTS (SELECT 1 FROM feedback f WHERE f.task_id = ? AND f.workspace_id = ? AND f.status = 'active' AND f.search @@ ?::text::tsquery)",
            t.id,
            t.workspace_id,
            ^ts
          )
        )
    end
  end

  defp positive(:description, :empty, _value, _scope),
    do: dynamic([task: t], t.description == "" or is_nil(t.description))

  defp positive(:owner, :eq, value, scope), do: owner(value, scope)

  defp positive(:squad, op, value, _scope) do
    squads =
      from(s in Squad,
        join: a in Actor,
        on: a.id == s.actor_id and a.workspace_id == s.workspace_id,
        left_join: m in Member,
        on: m.squad_id == s.id and m.workspace_id == s.workspace_id,
        where: s.workspace_id == parent_as(:task).workspace_id,
        where:
          s.actor_id == parent_as(:task).assignee_id or
            s.leader_agent_id == parent_as(:task).assignee_id or
            m.actor_id == parent_as(:task).assignee_id
      )

    squads =
      case op do
        :eq -> where(squads, [_, a], a.name == ^value)
        :in -> where(squads, [_, a], a.name in ^value)
      end

    dynamic(exists(subquery(select(squads, 1))))
  end

  defp positive(:owner, :in, values, scope),
    do: Enum.reduce(values, dynamic(false), fn v, acc -> dynamic(^acc or ^owner(v, scope)) end)

  # The column is int4, while BQL deliberately accepts arbitrary nonnegative
  # integers. Fold out-of-range comparisons before Postgrex encodes a parameter.
  defp positive(:feedback_count, op, value, _scope) when value > 2_147_483_647,
    do: dynamic(^(op in [:lt, :lte]))

  defp positive(field, :empty, _value, _scope) do
    expr = expression(field)
    dynamic(is_nil(^expr))
  end

  defp positive(field, op, value, _scope) do
    expr =
      if field == :priority and op in [:gt, :gte, :lt, :lte],
        do: sort_expression(:priority),
        else: expression(field)

    value =
      if field == :priority and op in [:gt, :gte, :lt, :lte],
        do: Enum.find_index(["low", "medium", "high"], &(&1 == value)) + 1,
        else: value

    compare(expr, op, value)
  end

  defp owner({:owner_id, id}, _scope),
    do:
      dynamic(
        [assignee: a],
        fragment(
          "(?::text IN ('human', 'agent')) AND COALESCE(?, ?) = ?",
          a.kind,
          a.user_id,
          a.owner_id,
          ^id
        )
      )

  defp owner(name, scope) do
    ws = scope.workspace.id

    dynamic(
      [assignee: a],
      fragment(
        "(?::text IN ('human', 'agent')) AND COALESCE(?, ?) IN (SELECT h.user_id FROM actors h WHERE h.workspace_id = ? AND h.kind = 'human' AND h.name = ?::citext)",
        a.kind,
        a.user_id,
        a.owner_id,
        ^ws,
        ^name
      )
    )
  end

  defp link(field, op, value) do
    {kind, source, target} = link_direction(field)

    links =
      from(l in "task_links",
        join: other in Task,
        on: other.id == field(l, ^target) and other.workspace_id == l.workspace_id,
        where:
          field(l, ^source) == parent_as(:task).id and
            l.workspace_id == parent_as(:task).workspace_id and l.type == ^kind
      )

    links =
      case op do
        :empty -> links
        :eq -> where(links, [_, other], other.ident == ^value)
        :in -> where(links, [_, other], other.ident in ^value)
      end

    predicate = dynamic(exists(subquery(select(links, 1))))
    if op == :empty, do: dynamic(not (^predicate)), else: predicate
  end

  defp link_direction(:depends_on), do: {"depends_on", :from_task_id, :to_task_id}
  defp link_direction(:blocks), do: {"depends_on", :to_task_id, :from_task_id}
  defp link_direction(:replaces), do: {"replaces", :from_task_id, :to_task_id}
  defp link_direction(:replaced_by), do: {"replaces", :to_task_id, :from_task_id}

  def expression(:project), do: dynamic([project: p], fragment("lower(?::text)", p.key))
  def expression(:id), do: dynamic([task: t], fragment("lower(?)", t.ident))
  def expression(:assignee), do: dynamic([assignee: a], fragment("lower(?::text)", a.name))
  def expression(:created_by), do: dynamic([creator: a], fragment("lower(?::text)", a.name))
  def expression(:assignee_kind), do: dynamic([assignee: a], fragment("?::text", a.kind))
  def expression(:created_by_kind), do: dynamic([creator: a], fragment("?::text", a.kind))
  def expression(:epic), do: dynamic([epic: e], fragment("lower(?)", e.ident))
  def expression(:run), do: dynamic([run: r], fragment("?::text", r.status))
  def expression(:pr), do: dynamic([pr: p], fragment("?::text", p.state))
  def expression(:ci), do: dynamic([pr: p], fragment("NULLIF(?::text, 'none')", p.checks_state))

  def expression(:merge),
    do: dynamic([pr: p], fragment("NULLIF(?::text, 'none')", p.merge_status))

  def expression(:created), do: dynamic([task: t], t.inserted_at)
  def expression(:updated), do: dynamic([task: t], t.updated_at)
  def expression(:question), do: dynamic([task: t], t.open_question)
  def expression(:title), do: dynamic([task: t], fragment("lower(?)", t.title))
  def expression(:description), do: dynamic([task: t], t.description)
  def expression(:feedback_count), do: dynamic([task: t], t.feedback_count)

  def expression(f) when f in [:status, :priority, :kind],
    do: dynamic([task: t], fragment("?::text", field(t, ^f)))

  def sort_expression(field) when field in [:priority, :status, :run, :pr] do
    expr = expression(field)

    values =
      case field do
        :status -> ~w(new in_progress done verified rejected cancelled)
        _ -> Fields.fetch(to_string(field)).values
      end

    dynamic(fragment("array_position(?::text[], ?)", ^values, ^expr))
  end

  def sort_expression(field), do: expression(field)

  defp compare(expr, :eq, value) when is_binary(value),
    do: dynamic(fragment("? = ?", ^expr, ^String.downcase(value)))

  defp compare(expr, :eq, value), do: dynamic(^expr == ^value)

  defp compare(expr, :in, values),
    do: dynamic(fragment("? = ANY(?::text[])", ^expr, ^Enum.map(values, &String.downcase/1)))

  defp compare(expr, :match, value), do: dynamic(fragment("? ILIKE ?", ^expr, ^pattern(value)))
  defp compare(expr, :gt, value), do: dynamic(^expr > ^value)
  defp compare(expr, :gte, value), do: dynamic(^expr >= ^value)
  defp compare(expr, :lt, value), do: dynamic(^expr < ^value)
  defp compare(expr, :lte, value), do: dynamic(^expr <= ^value)

  defp pattern(value),
    do:
      "%" <>
        (value
         |> String.replace("\\", "\\\\")
         |> String.replace("%", "\\%")
         |> String.replace("_", "\\_")) <> "%"

  defp tsquery(value) do
    case Query.parse(value) do
      {:ok, :blank} -> nil
      {:ok, groups} -> Query.to_tsquery(groups)
      {:error, reason} -> throw({:compile_error, reason})
    end
  end

  defp relevance(true), do: []
  defp relevance({:not, _}), do: []
  defp relevance({op, nodes}) when op in [:and, :or], do: Enum.flat_map(nodes, &relevance/1)

  defp relevance({:cond, field, :match, value}) when field in [:text, :feedback],
    do: [{field, tsquery(value)}]

  defp relevance(_), do: []

  def score(parts) do
    Enum.reduce(parts, dynamic(0.0), fn
      {_, nil}, acc ->
        acc

      {field, ts}, acc ->
        fb =
          dynamic(
            [task: t],
            fragment(
              "COALESCE((SELECT MAX(ts_rank_cd(f.search, ?::text::tsquery)) FROM feedback f WHERE f.task_id = ? AND f.workspace_id = ? AND f.status = 'active'), 0)",
              ^ts,
              t.id,
              t.workspace_id
            )
          )

        part =
          if field == :text,
            do:
              dynamic(
                [task: t],
                fragment("GREATEST(ts_rank_cd(?, ?::text::tsquery), ?)", t.search, ^ts, ^fb)
              ),
            else: fb

        dynamic(^acc + ^part)
    end)
  end
end

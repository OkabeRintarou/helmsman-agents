defmodule Helmsman.Runs.ReadModels do
  @moduledoc """
  Read-only views of runs for the web pages (`add-run-read-models`): the
  agents running on a batch of tasks, an agent's daily usage, and the open
  and finished runs of a task or a managed agent. Each one makes a fixed
  number of queries, whatever the number of tasks, agents or runs.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Workspaces.Workspace

  @max_idents 200
  @default_days 30
  @max_days 90
  @default_limit 50
  @max_pending_limit 200
  @max_finished_limit 100

  @type target :: {:task, String.t()} | {:agent, String.t()}
  @type day :: %{
          date: Date.t(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          cancelled: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost_usd: float() | nil
        }

  ## Active agents (R5)

  @doc """
  For each task among `idents` (at most #{@max_idents}) with a `claimed`,
  `running` or `cancelling` run, the names of those runs' agents, by
  claim time, without repeats (`:view_runs`). Other tasks, and idents
  that name no task of the workspace, are absent. One query.
  """
  @spec active_agents(Scope.t(), [String.t()]) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, :forbidden | :too_many}
  def active_agents(%Scope{workspace: %Workspace{id: workspace_id}} = scope, idents)
      when is_list(idents) do
    with :ok <- Policy.authorize(scope, :view_runs),
         {:ok, idents} <- normalize_idents(idents) do
      {:ok, active_agents_of(workspace_id, idents)}
    end
  end

  defp normalize_idents(idents) do
    idents = Enum.uniq(idents)

    if length(idents) > @max_idents do
      {:error, :too_many}
    else
      {:ok,
       for(
         ident <- idents,
         {:ok, ident, _key, _seq} <- [Ident.parse(ident)],
         uniq: true,
         do: ident
       )}
    end
  end

  defp active_agents_of(_workspace_id, []), do: %{}

  defp active_agents_of(workspace_id, idents) do
    from(t in Task,
      join: r in Run,
      on: r.task_id == t.id,
      join: a in Actor,
      on: a.id == r.agent_id,
      where:
        t.workspace_id == ^workspace_id and t.ident in ^idents and
          r.status in ^Run.active_statuses(),
      order_by: [asc: t.id, asc_nulls_last: r.claimed_at, asc: r.id],
      select: {t.ident, a.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {ident, names} -> {ident, Enum.uniq(names)} end)
  end

  ## Usage (R6)

  @doc """
  The managed agent `name`'s runs that ended in each of the last `days`
  UTC days, today included (`:view_runs`): per day the runs that
  succeeded, failed and were cancelled, the input and output tokens (an
  unreported count is 0) and the cost (nil when no run of the day
  reported one), oldest first, every day present; and the totals. An
  archived agent counts; an external agent or an unknown name is
  `:not_found`. Two queries: the agent, then the aggregate.

  ## Options

    * `:days` - 1 to #{@max_days} (default #{@default_days})
  """
  @spec usage_for_agent(Scope.t(), String.t(), keyword()) ::
          {:ok,
           %{
             days: [day()],
             totals: %{
               runs: non_neg_integer(),
               input_tokens: non_neg_integer(),
               output_tokens: non_neg_integer(),
               cost_usd: float() | nil
             }
           }}
          | {:error, :forbidden | :not_found | :invalid_days}
  def usage_for_agent(%Scope{workspace: %Workspace{id: workspace_id}} = scope, name, opts \\ [])
      when is_binary(name) do
    with :ok <- Policy.authorize(scope, :view_runs),
         {:ok, days} <- usage_days(opts),
         %Actor{} = agent <- managed_agent(workspace_id, name) || {:error, :not_found} do
      today = Date.utc_today()
      first = Date.add(today, 1 - days)
      by_date = usage_by_date(agent.id, first, today)

      days =
        for date <- Date.range(first, today) do
          Map.get(by_date, date, %{
            date: date,
            succeeded: 0,
            failed: 0,
            cancelled: 0,
            input_tokens: 0,
            output_tokens: 0,
            cost_usd: nil
          })
        end

      {:ok, %{days: days, totals: totals(days)}}
    end
  end

  defp usage_days(opts) when is_list(opts) do
    case Keyword.get(opts, :days, @default_days) do
      days when is_integer(days) and days in 1..@max_days -> {:ok, days}
      _invalid -> {:error, :invalid_days}
    end
  end

  defp usage_days(_opts), do: {:error, :invalid_days}

  # `finished_at` is a UTC `timestamp`, so its date is the UTC date.
  defp usage_by_date(agent_id, first, last) do
    from_at = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
    to_at = DateTime.new!(Date.add(last, 1), ~T[00:00:00], "Etc/UTC")

    from(r in Run,
      where:
        r.agent_id == ^agent_id and r.status in ^Run.ended_statuses() and
          r.finished_at >= ^from_at and r.finished_at < ^to_at,
      group_by: fragment("(?)::date", r.finished_at),
      select: %{
        date: type(fragment("(?)::date", r.finished_at), :date),
        succeeded: filter(count(r.id), r.status == ^:succeeded),
        failed: filter(count(r.id), r.status == ^:failed),
        cancelled: filter(count(r.id), r.status == ^:cancelled),
        input_tokens:
          type(fragment("COALESCE(SUM((?->>'input_tokens')::bigint), 0)", r.usage), :integer),
        output_tokens:
          type(fragment("COALESCE(SUM((?->>'output_tokens')::bigint), 0)", r.usage), :integer),
        cost_usd: type(fragment("SUM((?->>'cost_usd')::float8)", r.usage), :float)
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.date, &1})
  end

  defp totals(days) do
    costs = days |> Enum.map(& &1.cost_usd) |> Enum.reject(&is_nil/1)

    %{
      runs: Enum.sum(Enum.map(days, &(&1.succeeded + &1.failed + &1.cancelled))),
      input_tokens: Enum.sum(Enum.map(days, & &1.input_tokens)),
      output_tokens: Enum.sum(Enum.map(days, & &1.output_tokens)),
      cost_usd: if(costs == [], do: nil, else: Enum.sum(costs))
    }
  end

  ## Open runs (R9)

  @doc """
  The open runs of a task or a managed agent (`:view_runs`): `active`,
  every `claimed`, `running` or `cancelling` run by claim time, never
  paged; `pending`, the `queued` and `deferred` runs in claim order
  (higher priority first, then older first); and `pending_total`, their
  number when read. For a task `pending` is complete and the paging
  options are ignored (at most one pending run per agent and lane).

  Each call is right for the state it reads; a cursor kept across a
  change of the runs may repeat or skip runs, so after one read again
  from the first page (decision 9).

  ## Options (an agent)

    * `:pending_limit` - 1 to #{@max_pending_limit} (default #{@default_limit})
    * `:pending_after` - `{priority, inserted_at, id}` of the last pending
      run of the previous page
  """
  @spec list_open(Scope.t(), target(), keyword()) ::
          {:ok,
           %{
             active: [Runs.summary()],
             pending: [Runs.summary()],
             pending_total: non_neg_integer()
           }}
          | {:error, :forbidden | :not_found | :invalid_opts}
  def list_open(%Scope{workspace: %Workspace{id: workspace_id}} = scope, target, opts \\ []) do
    with :ok <- Policy.authorize(scope, :view_runs),
         {:ok, page} <- open_opts(target, opts),
         {:ok, owner} <- runs_of(workspace_id, target) do
      active = from(r in Run, where: r.status in ^Run.active_statuses())
      pending = from(r in Run, where: r.status in ^Run.pending_statuses())
      page_ids = pending |> of_target(owner) |> order_pending() |> pending_page(page)

      {total, runs} =
        snapshot(
          of_target(pending, owner),
          dynamic([run: r], r.id in subquery(page_ids) or r.id in subquery(ids(active, owner)))
        )

      {active, pending} = Enum.split_with(runs, &(&1.status in Run.active_statuses()))

      active = Enum.sort_by(active, &claim_key/1)
      pending = Enum.sort_by(pending, &pending_key/1)

      summaries = Runs.summaries(active ++ pending)
      {active, pending} = Enum.split(summaries, length(active))
      {:ok, %{active: active, pending: pending, pending_total: total}}
    end
  end

  # One statement, so one snapshot (READ COMMITTED takes one per
  # statement): the runs whose ID `on` selects and the number of rows of
  # `counted`. A run that changes status while the caller reads is listed
  # either before or after the change, never in neither or both lists,
  # and a page always agrees with its total. The summaries are read next;
  # they only add names and links, never decide which runs are listed.
  defp snapshot(counted, on) do
    count = from(r in counted, select: %{total: count(r.id)})

    listed = from(r in Run, as: :run, where: ^on)

    from(c in subquery(count), left_join: r in subquery(listed), on: true, select: {c.total, r})
    |> Repo.all()
    |> case do
      [{total, nil}] -> {total, []}
      rows -> {rows |> hd() |> elem(0), Enum.map(rows, &elem(&1, 1))}
    end
  end

  # The orders of the SQL reads, applied to rows read in one statement.
  defp claim_key(%Run{claimed_at: nil, id: id}), do: {1, 0, id}
  defp claim_key(%Run{claimed_at: at, id: id}), do: {0, DateTime.to_unix(at, :microsecond), id}

  defp pending_key(%Run{} = run),
    do: {-run.priority, DateTime.to_unix(run.inserted_at, :microsecond), run.id}

  defp of_target(query, {field, id}), do: where(query, [r], field(r, ^field) == ^id)

  defp ids(query, owner), do: query |> of_target(owner) |> select([r], r.id)

  defp pending_page(query, :all), do: select(query, [r], r.id)

  defp pending_page(query, {limit, after_key}),
    do: query |> after_pending(after_key) |> limit(^limit) |> select([r], r.id)

  defp open_opts(target, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:task, _ident} <- target do
      {:ok, :all}
    else
      false ->
        {:error, :invalid_opts}

      _agent ->
        with {:ok, limit} <- page_limit(opts[:pending_limit], @max_pending_limit),
             {:ok, after_key} <- pending_after(opts[:pending_after]) do
          {:ok, {limit, after_key}}
        end
    end
  end

  defp open_opts(_target, _opts), do: {:error, :invalid_opts}

  defp pending_after(nil), do: {:ok, nil}

  defp pending_after({priority, %DateTime{}, id} = key)
       when is_integer(priority) and is_integer(id),
       do: {:ok, key}

  defp pending_after(_cursor), do: {:error, :invalid_opts}

  # The order in which runs are claimed (`Helmsman.Runs.Claim`).
  defp order_pending(query),
    do: order_by(query, [r], desc: r.priority, asc: r.inserted_at, asc: r.id)

  defp after_pending(query, nil), do: query

  # Priority descends: compare its negation as a row value.
  defp after_pending(query, {priority, at, id}) do
    where(
      query,
      [r],
      fragment("(-?, ?, ?) > (?, ?, ?)", r.priority, r.inserted_at, r.id, ^(-priority), ^at, ^id)
    )
  end

  ## Finished runs (R10)

  @doc """
  The ended (`succeeded`, `failed`, `cancelled`) runs of a task or a
  managed agent, newest first by `(inserted_at, id)` (`:view_runs`), and
  `total`, their number when read. An ended run keeps its place in this
  order, but a run that ends later may land on either side of a cursor:
  after a change of the runs read again from the first page (decision 9).

  ## Options

    * `:limit` - 1 to #{@max_finished_limit} (default #{@default_limit})
    * `:before` - `{inserted_at, id}` of the last run of the previous page
  """
  @spec list_finished(Scope.t(), target(), keyword()) ::
          {:ok, %{runs: [Runs.summary()], total: non_neg_integer()}}
          | {:error, :forbidden | :not_found | :invalid_opts}
  def list_finished(%Scope{workspace: %Workspace{id: workspace_id}} = scope, target, opts \\ []) do
    with :ok <- Policy.authorize(scope, :view_runs),
         {:ok, limit, before} <- finished_opts(opts),
         {:ok, owner} <- runs_of(workspace_id, target) do
      ended = from(r in Run, where: r.status in ^Run.ended_statuses()) |> of_target(owner)

      page_ids =
        from(r in ended, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit, select: r.id)
        |> before(before)

      {total, runs} = snapshot(ended, dynamic([run: r], r.id in subquery(page_ids)))
      runs = Enum.sort_by(runs, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, :desc)
      {:ok, %{runs: Runs.summaries(runs), total: total}}
    end
  end

  defp finished_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, limit} <- page_limit(opts[:limit], @max_finished_limit),
         {:ok, before} <- before_key(opts[:before]) do
      {:ok, limit, before}
    else
      _invalid -> {:error, :invalid_opts}
    end
  end

  defp finished_opts(_opts), do: {:error, :invalid_opts}

  defp before_key(nil), do: {:ok, nil}
  defp before_key({%DateTime{}, id} = key) when is_integer(id), do: {:ok, key}
  defp before_key(_cursor), do: {:error, :invalid_opts}

  defp before(query, nil), do: query

  defp before(query, {at, id}),
    do: where(query, [r], fragment("(?, ?) < (?, ?)", r.inserted_at, r.id, ^at, ^id))

  ## Targets

  defp page_limit(nil, _max), do: {:ok, @default_limit}
  defp page_limit(n, max) when is_integer(n) and n >= 1 and n <= max, do: {:ok, n}
  defp page_limit(_n, _max), do: {:error, :invalid_opts}

  defp runs_of(workspace_id, {:task, ident}) when is_binary(ident) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident),
         id when is_integer(id) <-
           Repo.one(
             from(t in Task,
               where: t.workspace_id == ^workspace_id and t.ident == ^ident,
               select: t.id
             )
           ) do
      {:ok, {:task_id, id}}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp runs_of(workspace_id, {:agent, name}) when is_binary(name) do
    case managed_agent(workspace_id, name) do
      %Actor{id: id} -> {:ok, {:agent_id, id}}
      nil -> {:error, :not_found}
    end
  end

  defp runs_of(_workspace_id, _target), do: {:error, :not_found}

  # A managed agent of the workspace, archived or not.
  defp managed_agent(workspace_id, name) do
    Repo.one(
      from(a in Actor,
        join: p in AgentProfile,
        on: p.actor_id == a.id and p.workspace_id == a.workspace_id,
        where: a.workspace_id == ^workspace_id and a.name == ^name and a.kind == :agent
      )
    )
  end
end

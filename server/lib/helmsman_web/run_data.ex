defmodule HelmsmanWeb.RunData do
  @moduledoc """
  The web layer's single entry for reading agents, runtimes and runs (add-agents-runs-ui
  D2). Pages and components call this module, so a domain signature change touches one
  module.

  Placeholders (marked `PLACEHOLDER(domain-request-1 Rn)`) stand in for the read functions of
  `reviews/domain-request-1.md` that are not merged yet; tasks 5.2 replaces them with
  plain delegations.
  """
  alias Helmsman.{Agents, Daemons, Policy, Runs}

  @online_after_seconds 120
  @active ~w(claimed running cancelling)
  @pending ~w(queued deferred)
  @finished ~w(succeeded failed cancelled)
  @pending_page 200
  @finished_page 100
  @ranks %{viewer: 1, member: 2, admin: 3, owner: 4}

  ## Agents

  @doc """
  `Helmsman.Agents.list/1` with the R7 fields (`workspace_id`, `actor_id`,
  `last_run_at`).
  """
  def agents(scope) do
    :telemetry.execute([:helmsman_web, :run_data, :agents], %{count: 1}, %{
      workspace_id: scope.workspace.id
    })

    with {:ok, views} <- Agents.list(scope), do: {:ok, Enum.map(views, &complete(&1, scope))}
  end

  @doc "`Helmsman.Agents.get/2` with the R7 fields."
  def agent(scope, name) do
    with {:ok, view} <- Agents.get(scope, name), do: {:ok, complete(view, scope)}
  end

  # PLACEHOLDER(domain-request-1 R7): the views carry these fields once
  # add-run-read-models is merged; `Agents.list/get` already filter by the scope's
  # workspace.
  defp complete(view, scope) do
    view
    |> Map.put_new(:workspace_id, scope.workspace.id)
    |> Map.put_new(:actor_id, nil)
    |> Map.put_new(:last_run_at, nil)
  end

  @doc """
  What `scope` may do with the agent `view` (R7): `configure` (execution settings,
  enable) and `administer` (description and limits, disable, archive). Both are false
  for a view of another workspace.
  """
  # PLACEHOLDER(domain-request-1 R7): delegate to `Agents.permissions/2`.
  def agent_permissions(scope, %{workspace_id: workspace_id, owner: %{id: owner_id}}) do
    if workspace_id != scope.workspace.id do
      %{configure: false, administer: false}
    else
      owner? = role_at_least?(scope, :member) and owner_id == scope.user.id
      %{configure: owner?, administer: owner? or role_at_least?(scope, :admin)}
    end
  end

  defp role_at_least?(%{role: role}, min), do: Map.get(@ranks, role, 0) >= @ranks[min]

  @doc """
  Whether `scope` can dispatch each managed, unarchived agent of the workspace (R1):
  `%{name => %{result: :ok | {:skipped, reason}, runtime: runtime | nil}}`, `runtime`
  as in the agent view. An offline runtime is `:ok` (the run waits for it).
  """
  # PLACEHOLDER(domain-request-1 R1): delegate to `Helmsman.Dispatch.availability/1`.
  def availability(scope) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, views} <- Agents.list(scope) do
      {:ok,
       for view <- views, view.kind == "managed", not view.archived, into: %{} do
         {view.name, %{result: dispatchable(scope, view), runtime: view.runtime}}
       end}
    end
  end

  # The order of `Runs.enqueue/3` steps 1–2 (`Agents.trigger_check/3`, then the runtime).
  defp dispatchable(scope, view) do
    cond do
      view.disabled -> {:skipped, :agent_disabled}
      not may_trigger?(scope, view) -> {:skipped, :unauthorized}
      view.runtime == nil -> {:skipped, :no_runtime}
      view.runtime.disabled -> {:skipped, :runtime_disabled}
      true -> :ok
    end
  end

  defp may_trigger?(scope, view) do
    user = scope.user.id

    role_at_least?(scope, :member) and
      (view.owner.id == user or view.access == "workspace" or
         (view.access == "members" and user in (view.access_member_ids || [])))
  end

  ## Daemons

  @doc "The user's daemons with `online` (R8)."
  # PLACEHOLDER(domain-request-1 R8): `Daemons.list_own/1` returns `online`.
  def daemons(scope) do
    now = DateTime.utc_now()
    Enum.map(Daemons.list_own(scope), &Map.put_new(&1, :online, online?(&1, now)))
  end

  defp online?(%{revoked: true}, _now), do: false
  defp online?(%{last_seen_at: nil}, _now), do: false

  defp online?(%{last_seen_at: at}, now),
    do: DateTime.diff(now, at, :second) < @online_after_seconds

  ## Runs

  @doc "Statuses of runs in progress."
  def active_statuses, do: @active
  @doc "Statuses of runs waiting to be claimed."
  def pending_statuses, do: @pending
  @doc "Final statuses."
  def finished_statuses, do: @finished

  @doc """
  The runs of `target` (`{:task, ident}` or `{:agent, name}`) that are not finished
  (R9): `{:ok, %{active, pending, pending_total}}`; `active` complete, `pending` in claim
  order (`priority` desc, `inserted_at`, `id`), at most `pending_limit` after the
  `pending_after: {priority, inserted_at, id}` cursor.
  """
  def open_runs(scope, target, opts \\ []) do
    if exported?(:list_open, 3),
      do: runs().list_open(scope, target, opts),
      else: open_runs_interim(scope, target, opts)
  end

  @doc """
  The finished runs of `target`, newest first (R10): `{:ok, %{runs, total}}`, at most
  `limit` after the `before: {inserted_at, id}` cursor.
  """
  def finished_runs(scope, target, opts \\ []) do
    if exported?(:list_finished, 3),
      do: runs().list_finished(scope, target, opts),
      else: finished_runs_interim(scope, target, opts)
  end

  # PLACEHOLDER(domain-request-1 R9 R10): until add-run-read-models is merged the two
  # reads come from the newest runs (`Runs.list_for_task/2`, at most 50, and
  # `Runs.list_for_agent/3`, at most 100), so a task or agent with more runs than that
  # shows only those.
  defp open_runs_interim(scope, target, opts) do
    with {:ok, runs} <- recent_runs(scope, target) do
      pending =
        runs
        |> Enum.filter(&(&1.status in @pending))
        |> Enum.sort_by(&{-&1.priority, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})

      active =
        runs
        |> Enum.filter(&(&1.status in @active))
        |> Enum.sort_by(
          &{DateTime.to_unix(&1[:claimed_at] || &1.inserted_at, :microsecond), &1.id}
        )

      page =
        pending
        |> after_cursor(opts[:pending_after])
        |> Enum.take(opts[:pending_limit] || 50)

      {:ok, %{active: active, pending: page, pending_total: length(pending)}}
    end
  end

  defp after_cursor(runs, nil), do: runs

  defp after_cursor(runs, {priority, at, id}) do
    key = {-priority, DateTime.to_unix(at, :microsecond), id}

    Enum.drop_while(
      runs,
      &({-&1.priority, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id} <= key)
    )
  end

  defp finished_runs_interim(scope, target, opts) do
    with {:ok, runs} <- recent_runs(scope, target) do
      finished = Enum.filter(runs, &(&1.status in @finished))

      page =
        case opts[:before] do
          nil -> finished
          {at, id} -> Enum.drop_while(finished, &(not older?(&1, at, id)))
        end

      {:ok, %{runs: Enum.take(page, opts[:limit] || 50), total: length(finished)}}
    end
  end

  defp older?(run, at, id) do
    case DateTime.compare(run.inserted_at, at) do
      :lt -> true
      :eq -> run.id < id
      :gt -> false
    end
  end

  defp recent_runs(scope, {:task, ident}), do: Runs.list_for_task(scope, ident)
  defp recent_runs(scope, {:agent, name}), do: Runs.list_for_agent(scope, name, limit: 100)

  @doc """
  Reads the first `shown` items of a paged list (design D8a). `fun.(cursor)` reads one
  page (`cursor` is `nil` for the first) and returns `{:ok, %{items, total, next}}`
  (more keys allowed), `next` being the cursor of the following page or `nil`. The
  cursor of a page comes only from the previous page of this loop. Items are unique by
  `id`. Returns `{:ok, items, total, first_page}`.
  """
  def read_window(fun, shown) when is_function(fun, 1) and is_integer(shown) do
    with {:ok, first} <- fun.(nil) do
      collect(fun, shown, first, first.items, ids(first.items), first)
    end
  end

  defp collect(fun, shown, page, acc, seen, first) do
    if length(acc) >= shown or page.next == nil or page.items == [] do
      {:ok, Enum.take(acc, shown), page.total, first}
    else
      with {:ok, next} <- fun.(page.next) do
        new = Enum.reject(next.items, &MapSet.member?(seen, &1.id))
        collect(fun, shown, next, acc ++ new, MapSet.union(seen, ids(new)), first)
      end
    end
  end

  defp ids(items), do: MapSet.new(items, & &1.id)

  @doc """
  The open runs of `target` with the first `shown` pending ones (D8a): `{:ok, %{active,
  pending, pending_total}}`.
  """
  def open_window(scope, target, shown) do
    limit = shown |> max(1) |> min(@pending_page)

    fun = fn cursor ->
      opts = [pending_limit: limit] ++ if(cursor, do: [pending_after: cursor], else: [])
      scope |> open_runs(target, opts) |> invalid_opts!() |> open_page(limit)
    end

    with {:ok, pending, total, first} <- read_window(fun, shown) do
      {:ok, %{active: first.active, pending: pending, pending_total: total}}
    end
  end

  defp open_page({:ok, open}, limit) do
    next =
      if length(open.pending) < limit,
        do: nil,
        else: pending_cursor(List.last(open.pending))

    {:ok, %{items: open.pending, total: open.pending_total, next: next, active: open.active}}
  end

  defp open_page(error, _limit), do: error

  defp pending_cursor(run), do: {run.priority, run.inserted_at, run.id}

  @doc "The first `shown` finished runs of `target` and their total (D8a)."
  def finished_window(scope, target, shown) do
    limit = shown |> max(1) |> min(@finished_page)

    fun = fn cursor ->
      opts = [limit: limit] ++ if(cursor, do: [before: cursor], else: [])
      scope |> finished_runs(target, opts) |> invalid_opts!() |> finished_page(limit)
    end

    with {:ok, runs, total, _first} <- read_window(fun, shown),
         do: {:ok, %{runs: runs, total: total}}
  end

  defp finished_page({:ok, %{runs: runs, total: total}}, limit) do
    next =
      if length(runs) < limit,
        do: nil,
        else: {List.last(runs).inserted_at, List.last(runs).id}

    {:ok, %{items: runs, total: total, next: next}}
  end

  defp finished_page(error, _limit), do: error

  # The options are built here, never from the client: an invalid one is a bug (D2).
  defp invalid_opts!({:error, :invalid_opts}),
    do: raise(ArgumentError, "invalid run list options")

  defp invalid_opts!(result), do: result

  @doc "Whether `scope` may read execution events (`:view_run_events`, member and above)."
  def can_view_events?(scope) do
    if :view_run_events in Policy.actions(),
      do: Policy.authorize(scope, :view_run_events) == :ok,
      # PLACEHOLDER(add-run-lifecycle): the Policy action arrives with that change.
      else: role_at_least?(scope, :member)
  end

  @doc "The run `id` (`Runs.get/2`; with `error` for members once add-run-lifecycle is merged)."
  def run(scope, id), do: runs().get(scope, id)

  @doc """
  The execution events of the run `id` (R4): `{:ok, %{events, pruned, last_seq}}`, or
  `{:error, :unavailable}` before add-run-lifecycle is merged.
  """
  def events(scope, id, opts),
    do:
      if(exported?(:list_events, 3),
        do: runs().list_events(scope, id, opts),
        else: {:error, :unavailable}
      )

  @doc "Stops the run `id` (add-run-lifecycle)."
  def cancel(scope, id),
    do: if(exported?(:cancel, 2), do: runs().cancel(scope, id), else: {:error, :unavailable})

  @doc "Retries the run `id` (add-run-lifecycle)."
  def retry(scope, id),
    do: if(exported?(:retry, 2), do: runs().retry(scope, id), else: {:error, :unavailable})

  @doc """
  Whether `scope` may stop (`:cancel`) or retry (`:retry`) the run of `summary` (R3),
  regardless of its status; `false` before add-run-lifecycle is merged.
  """
  def can?(scope, action, summary) when action in [:cancel, :retry] do
    exported?(:can?, 3) and Map.has_key?(summary, :initiator) and
      runs().can?(scope, action, summary)
  end

  # The run functions of add-run-lifecycle and add-run-read-models go through the module
  # of `config :helmsman, HelmsmanWeb.RunData, runs: …` (default `Helmsman.Runs`), so
  # tests can stand in for them; functions not merged yet are skipped.
  defp runs, do: Application.get_env(:helmsman, __MODULE__, [])[:runs] || Runs

  defp exported?(fun, arity) do
    module = runs()
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end

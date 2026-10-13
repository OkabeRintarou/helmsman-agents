defmodule HelmsmanWeb.RunData do
  @moduledoc """
  The web layer's single entry for reading agents, runtimes and runs (add-agents-runs-ui
  D2). Pages and components call this module, so a domain signature change touches one
  module. The reads are those of `reviews/domain-request-1.md` (add-run-lifecycle,
  add-run-read-models); the windows over paged lists (D8a) are built here.
  """
  alias Helmsman.{Agents, Daemons, Dispatch, Policy, Runs}

  @active ~w(claimed running cancelling)
  @pending ~w(queued deferred)
  @finished ~w(succeeded failed cancelled)
  @pending_page 200
  @finished_page 100

  ## Agents

  @doc "`Helmsman.Agents.list/1` (R7 fields included)."
  def agents(scope) do
    :telemetry.execute([:helmsman_web, :run_data, :agents], %{count: 1}, %{
      workspace_id: scope.workspace.id
    })

    Agents.list(scope)
  end

  @doc "`Helmsman.Agents.get/2`."
  def agent(scope, name), do: Agents.get(scope, name)

  @doc """
  What `scope` may do with the agent `view` (R7): `configure` (execution settings,
  enable) and `administer` (description and limits, disable, archive).
  """
  def agent_permissions(scope, view), do: Agents.permissions(scope, view)

  @doc """
  Whether `scope` can dispatch each managed, unarchived agent of the workspace (R1):
  `%{name => %{result: :ok | {:skipped, reason}, runtime: runtime | nil}}`.
  """
  def availability(scope), do: Dispatch.availability(scope)

  ## Daemons

  @doc "The user's daemons, with `online` (R8)."
  def daemons(scope), do: Daemons.list_own(scope)

  ## Runs

  @doc "Statuses of runs in progress."
  def active_statuses, do: @active
  @doc "Statuses of runs waiting to be claimed."
  def pending_statuses, do: @pending
  @doc "Final statuses."
  def finished_statuses, do: @finished

  @doc """
  The runs of `target` (`{:task, ident}` or `{:agent, name}`) that are not finished
  (R9): `{:ok, %{active, pending, pending_total}}`.
  """
  def open_runs(scope, target, opts \\ []), do: Runs.list_open(scope, target, opts)

  @doc "The finished runs of `target`, newest first (R10): `{:ok, %{runs, total}}`."
  def finished_runs(scope, target, opts \\ []), do: Runs.list_finished(scope, target, opts)

  @doc """
  The agents with a run in progress on each task of `idents` (R5): `{:ok, %{ident =>
  [agent name]}}`.
  """
  def active_agents(scope, idents), do: Runs.active_agents(scope, idents)

  @doc "The runs and usage of agent `name` per day over the last `days` days (R6)."
  def usage(scope, name, days \\ 30), do: Runs.usage_for_agent(scope, name, days: days)

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

  @doc "Whether `scope` may read execution events (`:view_run_events`)."
  def can_view_events?(scope), do: Policy.authorize(scope, :view_run_events) == :ok

  @doc "The run `id` (`Runs.get/2`)."
  def run(scope, id), do: Runs.get(scope, id)

  @doc "The execution events of the run `id` (R4): `{:ok, %{events, pruned, last_seq}}`."
  def events(scope, id, opts), do: Runs.list_events(scope, id, opts)

  @doc "Stops the run `id`."
  def cancel(scope, id), do: Runs.cancel(scope, id)

  @doc "Retries the run `id`."
  def retry(scope, id), do: Runs.retry(scope, id)

  @doc """
  Whether `scope` may stop (`:cancel`) or retry (`:retry`) the run of `summary` (R3),
  regardless of its status.
  """
  def can?(scope, action, summary) when action in [:cancel, :retry],
    do: Runs.can?(scope, action, summary)
end

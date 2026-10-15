defmodule HelmsmanWeb.TaskLive.Board do
  @moduledoc "Per-column keyset windows and incremental updates for the project board."
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView
  alias Helmsman.Tasks
  alias HelmsmanWeb.{RunData, Throttle}
  alias HelmsmanWeb.TaskLive.Filter
  @page 25

  def init(socket) do
    socket =
      assign(socket,
        board: %{},
        board_rows: %{},
        board_counts: %{},
        board_columns: [],
        board_runs: %{},
        board_pending: MapSet.new(),
        board_panel: nil,
        board_announcement: ""
      )

    Enum.reduce(Filter.statuses(), socket, fn status, s ->
      name = stream_name(status)
      s |> stream_configure(name, dom_id: &"board-#{status}-#{&1.id}") |> stream(name, [])
    end)
  end

  def stream_name(status), do: String.to_existing_atom("board_" <> status)
  # Fixed atoms, never created from client input.
  defp names,
    do: [
      :board_new,
      :board_in_progress,
      :board_done,
      :board_verified,
      :board_rejected,
      :board_cancelled
    ]

  def clear(socket) do
    socket = Enum.reduce(names(), socket, &stream(&2, &1, [], reset: true)) |> clear_timers()

    assign(socket,
      board: %{},
      board_rows: %{},
      board_columns: [],
      board_runs: %{},
      board_pending: MapSet.new(),
      board_panel: nil
    )
  end

  defp clear_timers(socket) do
    timers = socket.assigns[:throttle_timers] || %{}

    Enum.each(Map.take(timers, [:board_counts, :board_search, :board_runs]), fn {_message, ref} ->
      Process.cancel_timer(ref)
    end)

    assign(
      socket,
      :throttle_timers,
      Map.drop(timers, [:board_counts, :board_search, :board_runs])
    )
  end

  def load(socket, filters) do
    columns =
      Enum.filter(
        Filter.statuses(),
        &(&1 in (filters[:status] || Filter.statuses() -- socket.assigns.view_prefs.hidden_columns))
      )

    socket =
      socket |> clear() |> assign(filters: filters, board_columns: columns, search_error: nil)

    socket = Enum.reduce(columns, socket, &read_column(&2, &1, @page, nil, true))
    counts(socket)
  end

  def counts(socket) do
    case Tasks.count_by_status(
           socket.assigns.current_scope,
           socket.assigns.project.key,
           Filter.domain_opts(socket.assigns.filters)
         ) do
      {:ok, counts} -> assign(socket, :board_counts, counts)
      _ -> socket
    end
  end

  def more(socket, status) do
    case socket.assigns.board[status] do
      %{more: true, cursor: cursor} -> read_column(socket, status, @page, cursor, false)
      _ -> socket
    end
  end

  defp read_column(socket, status, size, cursor, reset?) do
    %{current_scope: scope, project: project, filters: filters} = socket.assigns

    opts =
      Keyword.merge(Filter.domain_opts(filters),
        status: status,
        limit: min(size + 1, 200),
        before: cursor
      )

    case Tasks.list(scope, project.key, opts) do
      {:ok, tasks} ->
        taken = Enum.take(tasks, size)
        rows = Enum.map(taken, &Tasks.summary/1)
        runs = read_runs(scope, Enum.map(rows, & &1.id))

        old =
          if reset?,
            do: without_column(socket.assigns.board_rows, status),
            else: socket.assigns.board_rows

        rows_map = Map.merge(old, Map.new(rows, &{&1.id, &1}))
        last = List.last(taken)

        page = %{
          more: length(tasks) > size,
          cursor: if(last, do: {last.updated_at, last.id}, else: cursor)
        }

        socket
        |> assign(
          board_rows: rows_map,
          board: Map.put(socket.assigns.board, status, page),
          board_runs: Map.merge(socket.assigns.board_runs, runs)
        )
        |> stream(stream_name(status), Enum.map(rows, &decorate(&1, runs)), reset: reset?)

      {:error, {:invalid_query, _}} ->
        assign(
          socket,
          :search_error,
          Gettext.dgettext(HelmsmanWeb.Gettext, "ui", "最多 %{n} 个字符", n: 200)
        )

      _ ->
        socket
    end
  end

  defp without_column(rows, status),
    do: rows |> Enum.reject(fn {_id, row} -> row.status == status end) |> Map.new()

  def reload(socket) do
    Enum.reduce(socket.assigns.board_columns, socket, fn status, s ->
      size =
        max(Enum.count(s.assigns.board_rows, fn {_id, row} -> row.status == status end), @page)

      reread(s, status, size)
    end)
  end

  defp reread(socket, status, size) when size < 200,
    do: read_column(socket, status, size, nil, true)

  defp reread(socket, status, size) do
    socket = read_column(socket, status, 199, nil, true)

    if size > 199 and socket.assigns.board[status].more,
      do: read_remaining(socket, status, size - 199),
      else: socket
  end

  defp read_remaining(socket, _status, left) when left <= 0, do: socket

  defp read_remaining(socket, status, left) do
    page = socket.assigns.board[status]
    socket = read_column(socket, status, min(left, 199), page.cursor, false)

    if socket.assigns.board[status].more and left > 199,
      do: read_remaining(socket, status, left - 199),
      else: socket
  end

  def summary(socket, row) do
    socket = Throttle.schedule(socket, :board_counts, 1000)

    if Filter.search?(socket.assigns.filters) do
      Throttle.schedule(socket, :board_search, 1000)
    else
      old = socket.assigns.board_rows[row.id]

      matches? =
        Filter.match?(row, socket.assigns.filters) and row.status in socket.assigns.board_columns

      socket =
        if remove_old?(old, row, matches?),
          do:
            socket
            |> stream_delete(stream_name(old.status), old)
            |> assign(:board_rows, Map.delete(socket.assigns.board_rows, row.id)),
          else: socket

      socket =
        if matches? do
          runs = read_runs(socket.assigns.current_scope, [row.id])

          socket
          |> assign(
            board_rows: Map.put(socket.assigns.board_rows, row.id, row),
            board_runs: socket.assigns.board_runs |> Map.delete(row.id) |> Map.merge(runs)
          )
          |> stream_insert(
            stream_name(row.status),
            Map.put(decorate(row, runs), :highlight, true),
            at: 0
          )
        else
          assign(socket, :board_runs, Map.delete(socket.assigns.board_runs, row.id))
        end

      if old && (old.status != row.status or not Map.has_key?(socket.assigns.board_rows, row.id)),
        do: refill(socket, old.status),
        else: socket
    end
  end

  defp remove_old?(nil, _row, _matches?), do: false
  defp remove_old?(old, row, matches?), do: old != row or not matches?

  defp refill(socket, status) do
    empty? = not Enum.any?(socket.assigns.board_rows, fn {_id, row} -> row.status == status end)

    if (empty? and socket.assigns.board[status]) && socket.assigns.board[status].more,
      do: more(socket, status),
      else: socket
  end

  def run_updated(socket, ident) do
    if Map.has_key?(socket.assigns.board_rows, ident) do
      socket
      |> assign(:board_pending, MapSet.put(socket.assigns.board_pending, ident))
      |> Throttle.schedule(:board_runs)
    else
      socket
    end
  end

  def refresh_runs(socket) do
    ids = Enum.filter(socket.assigns.board_pending, &Map.has_key?(socket.assigns.board_rows, &1))
    fresh = read_runs(socket.assigns.current_scope, ids)
    changed = Enum.filter(ids, &(fresh[&1] != socket.assigns.board_runs[&1]))

    socket =
      assign(socket,
        board_pending: MapSet.new(),
        board_runs: socket.assigns.board_runs |> Map.drop(ids) |> Map.merge(fresh)
      )

    Enum.reduce(changed, socket, fn id, s ->
      row = s.assigns.board_rows[id]
      stream_insert(s, stream_name(row.status), decorate(row, fresh))
    end)
  end

  defp read_runs(_scope, []), do: %{}

  defp read_runs(scope, ids) do
    ids
    |> Enum.chunk_every(200)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case RunData.task_run_states(scope, chunk) do
        {:ok, states} -> Map.merge(acc, states)
        _ -> acc
      end
    end)
  end

  defp decorate(row, runs), do: Map.put(row, :run_state, runs[row.id])
end

defmodule HelmsmanWeb.API.RunsController do
  @moduledoc """
  `/runs`: start (`run_agent`) and stop (`cancel_run`) runs, and the
  REST-only run detail, execution events and retry (`add-rest-api`
  decisions 6 and 7).
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.Runs
  alias HelmsmanMCP.Present
  alias HelmsmanMCP.Tools.{CancelRun, RunAgent}
  alias HelmsmanWeb.API.Params
  alias OpenApiSpex.Schema

  tool_action(:create, RunAgent, status: 201, response: Schemas.RunResult, tag: "runs")

  tool_action(:cancel, CancelRun,
    path: [run_id: "id"],
    response: Schemas.RunResult,
    tag: "runs"
  )

  # The body of POST /runs/:id/retry, checked as tool arguments are.
  @retry_args %{actor: :string}

  @events_query %{after_seq: :integer, before_seq: :integer, latest: :boolean, limit: :integer}

  def show(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "get_run", fn ->
      with {:ok, id} <- ToolAction.positive_id(id),
           {:ok, scope} <- reader(conn),
           {:ok, run} <- Runs.get(scope, id) do
        ToolAction.data(conn, 200, run_view(run))
      end
    end)
  end

  def events(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "list_run_events", fn ->
      conn = Plug.Conn.fetch_query_params(conn)

      with {:ok, id} <- ToolAction.positive_id(id),
           {:ok, query} <- Params.convert_query(conn.query_params, @events_query),
           {:ok, scope} <- reader(conn),
           {:ok, page} <- Runs.list_events(scope, id, event_opts(query)) do
        ToolAction.data(conn, 200, %{page | events: Enum.map(page.events, &Present.run_event/1)})
      end
    end)
  end

  def retry(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "retry_run", fn ->
      with {:ok, id} <- ToolAction.positive_id(id),
           {:ok, _args, requested} <- Params.args(conn, @retry_args, %{}),
           {:ok, run} <-
             ToolAction.write(conn.assigns.current_scope, requested, &Runs.retry(&1, id)) do
        ToolAction.data(conn, 200, %{run: Present.run(run)})
      end
    end)
  end

  defp event_opts(query),
    do: Enum.map(query, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp reader(conn) do
    with {:ok, requested} <- Params.requested_actor(conn, nil),
         {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
         do: {:ok, scope}
  end

  # `Helmsman.Runs.get/2` adds the error text for members and above.
  defp run_view(run) do
    case Map.fetch(run, :error) do
      {:ok, error} -> run |> Present.run() |> Map.put(:error, error)
      :error -> Present.run(run)
    end
  end

  @id_param {:id, :path, %Schema{type: :integer, minimum: 1}, "Run ID."}

  @doc false
  def operation(:show) do
    Operations.manual(
      id: "get_run",
      summary: "get_run",
      description:
        "A run: agent, task, status, triggers; with its error text for members and above.",
      tag: "runs",
      params: [@id_param],
      response: Schemas.Run
    )
  end

  def operation(:events) do
    Operations.manual(
      id: "list_run_events",
      summary: "list_run_events",
      description:
        "The execution events of a run, by number (members and above). Default: the first " <>
          "events after after_seq (0); before_seq gives those right before it, latest=true " <>
          "the latest. A pruned run has no events left.",
      tag: "runs",
      params: [
        @id_param,
        {:after_seq, :query, %Schema{type: :integer}, "Events after this number."},
        {:before_seq, :query, %Schema{type: :integer}, "Instead, events before this number."},
        {:latest, :query, %Schema{type: :boolean}, "Instead, the latest events."},
        {:limit, :query, %Schema{type: :integer}, "At most this many events."}
      ],
      response: Schemas.RunEvents
    )
  end

  def operation(:retry) do
    Operations.manual(
      id: "retry_run",
      summary: "retry_run",
      description:
        "Retry a failed or cancelled run: returns the new queued run, or the retry already " <>
          "queued. Refusals are 409 (not_ended, not_retryable, already_retried, " <>
          "agent_disabled, agent_archived, no_runtime, runtime_disabled, task_closed, " <>
          "run_rate_limited).",
      tag: "runs",
      write: true,
      params: [@id_param],
      body: %Schema{
        type: :object,
        properties: %{actor: %Schema{type: :string, description: "Act as this agent of yours."}}
      },
      response: Schemas.RunResult
    )
  end
end

defmodule HelmsmanWeb.Telemetry do
  @moduledoc """
  Metrics shown by LiveDashboard (`/admin/dashboard`) and the pollers that
  measure them (`add-release-distribution` decision 5). Helmsman's own
  events carry counts, durations and status tags only: never a workspace
  name, task content or identity name.

    * `[:helmsman, :runs, :queued]` - polled every 30 seconds, `count` per
      `status` (`:queued`, `:deferred`)
    * `[:helmsman, :runs, :claim]` - a run is claimed: `wait_ms` since it
      was created
    * `[:helmsman, :runs, :finished]` - a run ended: `count` with `status`
      and `failure_reason`
    * `[:helmsman, :daemons, :online]` - polled every 30 seconds, `count`
    * `[:helmsman, :mcp, :tool_call]` - an MCP tool call: `duration`
      (native units) with `tool` and `result` (`:ok`, `:error`, `:internal`)
  """

  use Supervisor
  import Telemetry.Metrics

  alias Helmsman.{Daemons, Runs}

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
        # Add reporters as children of your supervision tree.
        # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
      ] ++ database_poller()

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("helmsman.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("helmsman.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("helmsman.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("helmsman.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("helmsman.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Helmsman
      last_value("helmsman.runs.queued.count",
        tags: [:status],
        description: "Pending runs by status (queued, deferred)"
      ),
      distribution("helmsman.runs.claim.wait_ms",
        unit: :millisecond,
        description: "Time from a run's creation to its claim"
      ),
      counter("helmsman.runs.finished.count",
        tags: [:status, :failure_reason],
        description: "Runs ended, by status and failure reason"
      ),
      last_value("helmsman.daemons.online.count", description: "Daemons online"),
      summary("helmsman.mcp.tool_call.duration",
        unit: {:native, :millisecond},
        tags: [:tool, :result],
        description: "MCP tool calls by tool and result"
      )
    ]
  end

  # The poller drops a measurement that raises for good, so a failing query
  # (the database restarting) only skips this round.

  @doc false
  # Polled every 30 seconds: pending runs by status.
  def measure_runs do
    for {status, count} <- Runs.count_pending() do
      :telemetry.execute([:helmsman, :runs, :queued], %{count: count}, %{status: status})
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  # Polled every 30 seconds: daemons online.
  def measure_daemons do
    :telemetry.execute([:helmsman, :daemons, :online], %{count: Daemons.count_online()}, %{})
  catch
    _kind, _reason -> :ok
  end

  # Database pollers; off in tests (`config :helmsman, HelmsmanWeb.Telemetry,
  # poll_database: false`), where they would run outside the sandbox.
  defp database_poller do
    if Application.get_env(:helmsman, __MODULE__, [])[:poll_database] == false do
      []
    else
      [
        Supervisor.child_spec(
          {:telemetry_poller,
           name: :helmsman_database_poller,
           measurements: [{__MODULE__, :measure_runs, []}, {__MODULE__, :measure_daemons, []}],
           period: :timer.seconds(30),
           init_delay: :timer.seconds(30)},
          id: :helmsman_database_poller
        )
      ]
    end
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {HelmsmanWeb, :count_users, []}
    ]
  end
end

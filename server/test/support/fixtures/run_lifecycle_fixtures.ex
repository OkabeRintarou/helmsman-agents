defmodule Helmsman.RunLifecycleFixtures do
  @moduledoc """
  Drives runs through the daemon side of add-run-lifecycle for web tests
  (add-agents-runs-ui D16): claim, start, report events, finish. The
  daemon context is that of the daemon the agent's runtime belongs to.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Repo, Runs}
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{Event, Report}

  @base_url "http://localhost:4000"

  @doc "The daemon context of the daemon `agent`'s runtime belongs to."
  def dctx(%Actor{} = agent), do: daemon_ctx(daemon_of(agent))

  @doc "Claims every claimable run of `agent`'s daemon; returns the claimed run ids."
  def claim!(%Actor{} = agent) do
    {:ok, specs} = Runs.claim(dctx(agent), @base_url)
    Enum.map(specs, & &1.run_id)
  end

  @doc "Reports `starting` for the claimed run `run_id`: the run is `running`."
  def start!(%Actor{} = agent, run_id) do
    {:ok, :proceed} = Runs.starting(dctx(agent), run_id)
    run_id
  end

  @doc """
  A run of `agent` in `running` (inserted claimed by its daemon, then started
  with `Runs.starting/2`), so events can be appended. `attrs` as in `run_fixture/2`.
  """
  def running_run!(%Actor{} = agent, attrs \\ %{}) do
    daemon = daemon_of(agent)

    run =
      run_fixture(
        agent,
        Map.merge(attrs, %{status: :claimed, daemon_id: daemon.id, claimed_at: now()})
      )

    start!(agent, run.id)
    Repo.get!(Run, run.id)
  end

  @doc "A protocol event `seq` of `type` (a text event by default)."
  def event(seq, type \\ :text, data \\ nil) do
    {:ok, event} =
      Event.new(%{seq: seq, type: type, data: data || %{text: "第 #{seq} 条"}, at: now()})

    event
  end

  @doc "Reports `events` (protocol events or sequence numbers) for the run `run_id`."
  def append!(%Actor{} = agent, run_id, events) do
    events = Enum.map(events, fn e -> if is_integer(e), do: event(e), else: e end)

    events
    |> Enum.chunk_every(200)
    |> Enum.each(fn chunk -> {:ok, _} = Runs.append_events(dctx(agent), run_id, chunk) end)
  end

  @doc "Reports the end of the run `run_id` (`status` with optional report fields)."
  def finish!(%Actor{} = agent, run_id, status \\ :succeeded, attrs \\ %{}) do
    {:ok, report} = Report.Finished.new(Map.merge(%{run_id: run_id, status: status}, attrs))
    :ok = Runs.finish(dctx(agent), report)
  end

  @doc "Sets columns of the run `run_id` directly (timestamps for ordering tests)."
  def set_run!(run_id, changes),
    do: Repo.update_all(from(r in Run, where: r.id == ^run_id), set: changes)

  defp now, do: DateTime.utc_now()
end

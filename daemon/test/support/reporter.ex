defmodule HelmsmanDaemon.TestReporter do
  @moduledoc "Deterministic protocol reporter forwarding all submissions to the test owner."
  use GenServer
  alias HelmsmanProtocol.Reply
  alias HelmsmanProtocol.Report
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def report(id, payload) do
    ref = make_ref()
    GenServer.cast(__MODULE__, {:report, id, payload, self(), ref})
    ref
  end

  def configure(fun), do: GenServer.call(__MODULE__, {:configure, fun})
  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner), response: &default/1}}
  @impl true
  def handle_call({:configure, fun}, _, state), do: {:reply, :ok, %{state | response: fun}}
  @impl true
  def handle_cast({:report, id, payload, caller, ref}, state) do
    send(state.owner, {:report, id, payload, caller, ref, System.monotonic_time(:millisecond)})

    case state.response.(payload) do
      :hold -> :ok
      {:reject, reason} -> send(caller, {:report_rejected, :invalid_payload, reason})
      response -> send(caller, {:report_result, ref, response})
    end

    {:noreply, state}
  end

  def default(%Report.Starting{}), do: {:ok, %Reply.Starting{action: :proceed, reason: nil}}

  def default(%Report.Events{events: events}),
    do: {:ok, %Reply.Events{acked_seq: List.last(events).seq}}

  def default(%Report.GitToken{}),
    do:
      {:ok,
       %Reply.GitToken{
         token: "ghs_RENEWED_TOKEN",
         expires_at: DateTime.add(DateTime.utc_now(), 3600)
       }}

  def default(_), do: {:ok, %Reply.Empty{}}
end

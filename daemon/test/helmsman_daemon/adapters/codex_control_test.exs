defmodule HelmsmanDaemon.Adapters.CodexControlTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.CodexFixtures

  test "interrupt addresses current turn and signal is the handshake fallback" do
    state = Codex.init_state(spec(1))
    assert Codex.interrupt(state) == :signal
    assert Codex.steer("hello", state) == :unsupported
    state = %{state | session_id: "t-1", turn_id: "u-1"}
    assert {:write, bytes} = Codex.interrupt(state)

    assert JSON.decode!(bytes) == %{
             "jsonrpc" => "2.0",
             "id" => "interrupt",
             "method" => "turn/interrupt",
             "params" => %{"threadId" => "t-1", "turnId" => "u-1"}
           }

    {_, actions, ended} = CodexFixtures.replay("interrupted", spec(1))
    assert :close_stdin in actions
    assert {{:failed, :cli_error, "turn interrupted"}, _} = Codex.finish(0, ended)
    assert Codex.interrupt(ended) == :signal
    assert Codex.steer("hello", ended) == :unsupported
  end

  test "steer IDs increase and real success and rejection responses become status events" do
    state = %{Codex.init_state(spec(1)) | session_id: "t-1", turn_id: "u-1"}
    assert {:ok, bytes, state} = Codex.steer("Also update README", state)
    assert JSON.decode!(bytes)["id"] == 100

    assert JSON.decode!(bytes)["params"] == %{
             "threadId" => "t-1",
             "expectedTurnId" => "u-1",
             "input" => [%{"type" => "text", "text" => "Also update README"}]
           }

    assert {:ok, bytes, state} = Codex.steer("Second", state)
    assert JSON.decode!(bytes)["id"] == 101
    replies = CodexFixtures.values("steer_ok") |> Enum.filter(&(&1["id"] in [100, 101]))

    {events, state} =
      Enum.reduce(replies, {[], state}, fn value, {events, state} ->
        {next, [], state} = Codex.handle_output(:stdout, JSON.encode!(value), state)
        {events ++ next, state}
      end)

    assert Enum.any?(events, fn {:status, data} ->
             data.level == :info and data.message == "steer delivered"
           end)

    assert Enum.any?(events, fn {:status, data} ->
             data.level == :warning and data.message =~ "expected active turn"
           end)

    assert MapSet.size(state.pending_steers) == 0
  end
end

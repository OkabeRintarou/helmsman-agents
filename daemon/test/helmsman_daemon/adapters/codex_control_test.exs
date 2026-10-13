defmodule HelmsmanDaemon.Adapters.CodexControlTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.CodexFixtures

  test "interrupt addresses current turn and signal is the handshake fallback" do
    state = Codex.init_state(spec(1))
    assert Codex.interrupt(state) == :signal
    assert Codex.steer(31, "hello", state) == :unsupported
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
    assert Codex.steer(31, "hello", ended) == :unsupported
  end

  # add-run-steering 2.2: codex-adapter「中断与插话」, with the recorded
  # steer_ok fixture (one accepted, one rejected reply).
  test "steering is pending until the reply; each reply settles its own reference" do
    state = %{Codex.init_state(spec(1)) | session_id: "t-1", turn_id: "u-1"}
    assert {:ok, bytes, :pending, state} = Codex.steer(31, "Also update README", state)
    assert JSON.decode!(bytes)["id"] == 100
    assert JSON.decode!(bytes)["method"] == "turn/steer"

    assert JSON.decode!(bytes)["params"] == %{
             "threadId" => "t-1",
             "expectedTurnId" => "u-1",
             "input" => [%{"type" => "text", "text" => "Also update README"}]
           }

    assert {:ok, bytes, :pending, state} = Codex.steer(32, "Second", state)
    assert JSON.decode!(bytes)["id"] == 101
    assert state.pending_steers == %{100 => 31, 101 => 32}

    replies =
      CodexFixtures.values("steer_ok")
      |> Enum.filter(&(&1["id"] in [100, 101]))
      |> Enum.sort_by(& &1["id"])

    assert [%{"id" => 100, "error" => _} = rejected, %{"id" => 101} = ok] = replies

    assert {[{:status, %{level: :warning, message: warning}}],
            [{:steer_result, 31, {:rejected, reason}}], state} =
             Codex.handle_output(:stdout, JSON.encode!(rejected), state)

    assert warning =~ "expected active turn"
    assert reason =~ "expected active turn"
    assert state.pending_steers == %{101 => 32}

    assert {[{:status, %{level: :info, message: "steer delivered"}}],
            [{:steer_result, 32, :delivered}], state} =
             Codex.handle_output(:stdout, JSON.encode!(ok), state)

    assert state.pending_steers == %{}

    # A reply nobody waits for settles nothing.
    assert {[], [], ^state} = Codex.handle_output(:stdout, JSON.encode!(ok), state)
  end

  test "the steer_rejected fixture: a rejection, then an accepted retry" do
    state = %{Codex.init_state(spec(1)) | session_id: "t-1", turn_id: "u-1"}
    {:ok, _bytes, :pending, state} = Codex.steer(7, "x", state)
    {:ok, _bytes, :pending, state} = Codex.steer(7, "x", state)
    values = CodexFixtures.values("steer_rejected")
    rejected = Enum.find(values, &(&1["id"] == 100))
    ok = Enum.find(values, &(&1["id"] == 101))

    assert {[{:status, %{level: :warning}}], [{:steer_result, 7, {:rejected, reason}}], state} =
             Codex.handle_output(:stdout, JSON.encode!(rejected), state)

    assert reason =~ "wrong-turn"

    assert {_events, [{:steer_result, 7, :delivered}], _state} =
             Codex.handle_output(:stdout, JSON.encode!(ok), state)
  end
end

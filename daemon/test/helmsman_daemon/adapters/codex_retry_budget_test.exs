defmodule HelmsmanDaemon.Adapters.CodexRetryTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.CodexFixtures

  for name <- ["error_network_tls", "error_network"] do
    test "#{name} stops after a five-minute retry segment" do
      values = CodexFixtures.values(unquote(name))
      error = Enum.find(values, &(&1["method"] == "error"))

      state = %{
        Codex.init_state(spec(1))
        | session_id: error["params"]["threadId"],
          turn_id: error["params"]["turnId"],
          clock: fn -> Process.get(:codex_time, 0) end
      }

      Process.put(:codex_time, 0)
      {_, [], state} = send_frame(error, state)
      Process.put(:codex_time, 299_999)
      {_, [], state} = send_frame(error, state)
      Process.put(:codex_time, 300_000)
      {[{:status, _}], [{:write, bytes}, :close_stdin], state} = send_frame(error, state)
      assert JSON.decode!(bytes)["method"] == "turn/interrupt"
      assert state.closed?
      assert {{:failed, :provider_network, message}, _} = Codex.finish(0, state)
      assert message =~ "5 minutes"
      assert message =~ error["params"]["error"]["message"]
    end
  end

  test "progress clears retry segment for only the current thread, including deltas" do
    error = %{
      "method" => "error",
      "params" => %{
        "threadId" => "t-1",
        "willRetry" => true,
        "error" => %{
          "message" => "retry",
          "codexErrorInfo" => %{"responseStreamDisconnected" => %{"httpStatusCode" => nil}}
        }
      }
    }

    for method <-
          ~w(item/started item/completed item/agentMessage/delta item/commandExecution/outputDelta thread/tokenUsage/updated turn/completed) do
      state = %{
        Codex.init_state(spec(1))
        | session_id: "t-1",
          turn_id: "u-1",
          clock: fn -> Process.get(:codex_time, 0) end
      }

      Process.put(:codex_time, 0)
      {_, [], state} = send_frame(error, state)
      Process.put(:codex_time, 200_000)

      {_, _, state} =
        send_frame(%{"method" => method, "params" => %{"threadId" => "child"}}, state)

      assert state.retry_started_at == 0
      {_, _, state} = send_frame(%{"method" => method, "params" => %{"threadId" => "t-1"}}, state)
      assert state.retry_started_at == nil
      Process.put(:codex_time, 300_000)
      {_, [], state} = send_frame(error, state)
      refute state.closed?
      Process.put(:codex_time, 600_000)
      {_, [_, :close_stdin], _} = send_frame(error, state)
    end
  end

  test "final errors bypass retry budget, and unstarted turns only close stdin" do
    state = %{
      Codex.init_state(spec(1))
      | session_id: "t-1",
        clock: fn -> Process.get(:codex_time, 0) end
    }

    frame = %{
      "method" => "error",
      "params" => %{
        "threadId" => "t-1",
        "willRetry" => false,
        "error" => %{"codexErrorInfo" => "unauthorized", "message" => "unauthorized"}
      }
    }

    {_, [], state} = send_frame(frame, state)
    assert {{:failed, :provider_auth, _}, _} = Codex.finish(0, state)
    state = %{state | error: nil}
    frame = put_in(frame, ["params", "willRetry"], true)
    frame = put_in(frame, ["params", "error"], %{"message" => "network"})
    Process.put(:codex_time, 0)
    {_, [], state} = send_frame(frame, state)
    Process.put(:codex_time, 300_000)
    {_, [:close_stdin], state} = send_frame(frame, state)
    assert {{:failed, :provider_network, _}, _} = Codex.finish(0, state)
  end

  defp send_frame(frame, state), do: Codex.handle_output(:stdout, JSON.encode!(frame), state)
end

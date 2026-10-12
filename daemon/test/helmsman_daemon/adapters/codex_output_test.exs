defmodule HelmsmanDaemon.Adapters.CodexOutputTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.CodexFixtures

  test "real successful fixtures normalize tools, close stdin and report per-turn usage" do
    for name <- [
          "success_text",
          "success_shell",
          "success_big_output",
          "success_mcp_tool",
          "resume_ok"
        ] do
      {events, actions, state} = CodexFixtures.replay(name, spec(1))
      assert :close_stdin in actions
      assert {:succeeded, meta} = Codex.finish(0, state)
      assert meta.session_id != nil
      assert List.last(events) |> elem(0) == :result
      assert Enum.at(events, -2) |> elem(0) == :usage
      assert Enum.any?(events, &(elem(&1, 0) == :session))
      values = CodexFixtures.values(name)

      usage =
        values
        |> Enum.filter(
          &(&1["method"] == "thread/tokenUsage/updated" and
              &1["params"]["turnId"] == state.turn_id)
        )
        |> Enum.map(& &1["params"]["tokenUsage"]["last"])

      assert meta.usage.input_tokens == Enum.sum(Enum.map(usage, & &1["inputTokens"]))
      assert meta.usage.cost_usd == nil

      if name == "success_mcp_tool",
        do:
          assert(
            Enum.any?(events, fn {type, data} ->
              type == :tool_call and data.name == "mcp__helmsman__whoami"
            end)
          )

      if name == "success_big_output",
        do:
          assert(
            Enum.any?(events, fn {type, data} ->
              type == :tool_result and data.truncated and byte_size(data.output) <= 16_384
            end)
          )
    end
  end

  test "handshake responds with turn/start and omits empty effort" do
    state = Codex.init_state(spec(1))

    {events, [{:write, bytes}], state} =
      send_frame(%{"id" => 2, "result" => %{"thread" => %{"id" => "t-1"}}}, state)

    assert events == [{:session, %{session_id: "t-1"}}]
    frame = JSON.decode!(bytes)
    assert frame["id"] == 3
    assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello"}]
    refute Map.has_key?(frame["params"], "effort")
    {[{:status, _}], [], _} = Codex.handle_output(:stdout, "garbage", state)

    {[], [], state} =
      send_frame(
        %{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "child",
            "turn" => %{"id" => "u-2", "status" => "completed"}
          }
        },
        state
      )

    refute state.closed?
  end

  test "runtime MCP guard interrupts active turns or closes handshake" do
    for active? <- [false, true] do
      state = %{
        Codex.init_state(spec(1))
        | session_id: "t-1",
          turn_id: if(active?, do: "u-1", else: nil)
      }

      {[{:status, _}], actions, state} =
        send_frame(
          %{
            "method" => "mcpServer/startupStatus/updated",
            "params" => %{"name" => "userdocs", "status" => "starting"}
          },
          state
        )

      if active?,
        do: assert(match?([{:write, _}], actions)),
        else: assert(actions == [:close_stdin])

      assert {{:failed, :cli_error, error}, _} = Codex.finish(0, state)
      assert error =~ "userdocs"
    end

    {events, _, state} = CodexFixtures.replay("mcp_failed", spec(1))

    assert Enum.any?(events, fn {type, data} ->
             type == :status and data.message =~ "Helmsman MCP failed"
           end)

    assert {:succeeded, _} = Codex.finish(0, state)
  end

  test "server requests are approved or rejected using generated schema responses" do
    state = Codex.init_state(spec(1))

    for {method, expected} <- [
          {"item/commandExecution/requestApproval", %{"decision" => "acceptForSession"}},
          {"item/fileChange/requestApproval", %{"decision" => "acceptForSession"}},
          {"execCommandApproval", %{"decision" => "approved_for_session"}},
          {"applyPatchApproval", %{"decision" => "approved_for_session"}},
          {"item/permissions/requestApproval",
           %{"permissions" => %{"network" => %{"enabled" => true}}, "scope" => "session"}},
          {"mcpServer/elicitation/request", %{"action" => "decline"}}
        ] do
      {[{:status, _}], [{:write, bytes}], _} =
        send_frame(
          %{
            "id" => "request",
            "method" => method,
            "params" => %{"permissions" => %{"network" => %{"enabled" => true}}}
          },
          state
        )

      assert JSON.decode!(bytes)["result"] == expected
    end

    for method <- ["item/tool/requestUserInput", "unknown"] do
      {_, [{:write, bytes}], _} = send_frame(%{"id" => 9, "method" => method}, state)
      assert JSON.decode!(bytes)["error"]["code"] == -32_601
      assert JSON.decode!(bytes)["error"]["message"] =~ "add_feedback"
    end

    {[{:status, _}], [], _} =
      send_frame(%{"id" => 9, "method" => "unknown"}, %{state | closed?: true})
  end

  test "two requests accumulate only current turn and child usage is excluded" do
    state = %{Codex.init_state(spec(1)) | session_id: "t-1", turn_id: "u-1"}

    state =
      Enum.reduce([{"old", 1_000}, {"u-1", 100}, {"u-1", 50}], state, fn {turn, count}, state ->
        {_, _, state} =
          send_frame(
            %{
              "method" => "thread/tokenUsage/updated",
              "params" => %{
                "threadId" => "t-1",
                "turnId" => turn,
                "tokenUsage" => %{"last" => %{"inputTokens" => count}}
              }
            },
            state
          )

        state
      end)

    {_, [:close_stdin], state} =
      send_frame(
        %{
          "method" => "turn/completed",
          "params" => %{"threadId" => "t-1", "turn" => %{"id" => "u-1", "status" => "completed"}}
        },
        state
      )

    assert state.usage.input_tokens == 150
  end

  test "tool completions without starts, thinking and warnings normalize safely" do
    state = Codex.init_state(spec(1))

    items = [
      %{
        "id" => "shell",
        "type" => "commandExecution",
        "command" => "false",
        "aggregatedOutput" => "bad",
        "status" => "completed",
        "exitCode" => 1
      },
      %{
        "id" => "patch",
        "type" => "fileChange",
        "changes" => [%{"kind" => %{"type" => "add"}, "path" => "hello.txt"}],
        "status" => "completed"
      },
      %{
        "id" => "mcp",
        "type" => "mcpToolCall",
        "server" => "helmsman",
        "tool" => "whoami",
        "arguments" => %{},
        "status" => "failed",
        "error" => %{"message" => "failed"}
      },
      %{"id" => "web", "type" => "webSearch", "query" => "test"}
    ]

    for item <- items do
      {[{:tool_call, call}, {:tool_result, result}], [], _} =
        send_frame(%{"method" => "item/completed", "params" => %{"item" => item}}, state)

      assert call.call_id == item["id"]
      assert result.call_id == item["id"]
      assert result.is_error == item["id"] in ["shell", "mcp"]
    end

    {[{:thinking, %{text: "one\n\ntwo"}}], [], _} =
      send_frame(
        %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "reasoning", "summary" => ["one", "two"]}}
        },
        state
      )

    for method <- ~w(configWarning warning deprecationNotice model/rerouted thread/compacted) do
      {[{:status, _}], [], _} =
        send_frame(%{"method" => method, "params" => %{"message" => "message"}}, state)
    end
  end

  test "usage preceding turn/start response is retained and foreign threads are excluded" do
    state = %{Codex.init_state(spec(1)) | session_id: "t-1"}

    state =
      Enum.reduce(
        [{"t-1", "old", 900}, {"child", "u-1", 1_000}, {"t-1", "u-1", 20}],
        state,
        fn {thread, turn, count}, state ->
          {_, _, state} =
            send_frame(
              %{
                "method" => "thread/tokenUsage/updated",
                "params" => %{
                  "threadId" => thread,
                  "turnId" => turn,
                  "tokenUsage" => %{"last" => %{"inputTokens" => count}}
                }
              },
              state
            )

          state
        end
      )

    {_, _, state} = send_frame(%{"id" => 3, "result" => %{"turn" => %{"id" => "u-1"}}}, state)

    {_, [:close_stdin], state} =
      send_frame(
        %{
          "method" => "turn/completed",
          "params" => %{"threadId" => "t-1", "turn" => %{"id" => "u-1", "status" => "completed"}}
        },
        state
      )

    assert state.usage.input_tokens == 20
  end

  defp send_frame(frame, state), do: Codex.handle_output(:stdout, JSON.encode!(frame), state)
end

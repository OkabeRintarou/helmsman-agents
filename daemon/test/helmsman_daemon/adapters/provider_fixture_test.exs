defmodule HelmsmanDaemon.Adapters.ProviderFixtureTest do
  use ExUnit.Case, async: true
  import HelmsmanDaemon.Case, only: [spec: 1]
  alias HelmsmanDaemon.Adapters.{Claude, Codex}

  @root Path.expand("../../fixtures", __DIR__)

  test "recorded Claude initialization sources remain distinct and the 401 is CLI consumable" do
    helper = values("claude", "provider_helper_init")
    user = values("claude", "provider_user_init")
    assert hd(helper)["apiKeySource"] == "apiKeyHelper"
    assert hd(user)["apiKeySource"] == "ANTHROPIC_API_KEY"

    {_, state} = claude_replay("provider_user_401")

    assert {{:failed, :cli_error, message}, _} = Claude.finish(1, state)
    assert message =~ "401 Probe authentication rejected"
  end

  test "the single real z.ai result replays as success without provider credentials" do
    {events, state} = claude_replay("provider_zai_success")
    assert Enum.any?(events, &match?({:result, %{success: true}}, &1))
    assert {:succeeded, %{summary: "OK"}} = Claude.finish(0, state)
  end

  test "recorded Codex start and resume report the reserved provider and 401 reports failure" do
    assert [%{"id" => 2, "result" => start}] = values("codex", "provider_thread_start")
    assert start["modelProvider"] == "helmsman_account"
    assert start["thread"]["modelProvider"] == "helmsman_account"
    rows = values("codex", "provider_error_401")
    resume = Enum.find(rows, &(&1["id"] == 4))
    assert resume["result"]["modelProvider"] == "helmsman_account"

    state = Codex.init_state(%{spec(1) | agent: %{spec(1).agent | provider: :codex}})

    state =
      Enum.reduce(rows, state, fn row, acc ->
        {_, _, next} = Codex.handle_output(:stdout, JSON.encode!(row), acc)
        next
      end)

    assert {{:failed, :provider_auth, _}, _} = Codex.finish(0, state)
  end

  defp values(cli, name) do
    @root
    |> Path.join(cli)
    |> Path.join(name <> ".jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp claude_replay(name) do
    Enum.reduce(values("claude", name), {[], Claude.init_state(spec(1))}, fn row,
                                                                             {events, state} ->
      {next, _, state} = Claude.handle_output(:stdout, JSON.encode!(row), state)
      {events ++ next, state}
    end)
  end
end

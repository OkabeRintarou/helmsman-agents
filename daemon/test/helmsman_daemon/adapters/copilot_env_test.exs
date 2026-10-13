defmodule HelmsmanDaemon.Adapters.CopilotEnvTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot
  alias HelmsmanDaemon.Adapters.Copilot.Environment

  test "cleans outer session and agent environment after merging, preserving login and BYOK" do
    base = %{
      "HOME" => "user",
      "GH_CONFIG_DIR" => "gh",
      "COPILOT_HOME" => "outer",
      "COPILOT_AGENT_SESSION_ID" => "outer-session",
      "COPILOT_CLI" => "1",
      "COPILOT_PROVIDER_BASE_URL" => "provider",
      "COPILOT_GH_HOST" => "host"
    }

    agent = %{
      "COPILOT_ALLOW_ALL" => "true",
      "COPILOT_GITHUB_TOKEN" => "dummy",
      "COPILOT_CUSTOM_INSTRUCTIONS_DIRS" => "instructions",
      "COPILOT_MODEL" => "model"
    }

    run = spec(1)
    run = %{run | agent: %{run.agent | env: agent, custom_args: []}}
    env = HelmsmanDaemon.Env.agent(base, agent)
    assert {:ok, launch} = Copilot.prepare(run, Paths.run(1), Paths.home(), env)
    actual = env |> Map.drop(launch.drop_env) |> Map.merge(Map.new(launch.env))
    assert actual["COPILOT_HOME"] == Paths.copilot_home()
    assert actual["COPILOT_AUTO_UPDATE"] == "false"
    assert actual["COPILOT_GITHUB_TOKEN"] == "dummy"
    assert actual["COPILOT_PROVIDER_BASE_URL"] == "provider"
    assert actual["HOME"] == "user"
    assert actual["GH_CONFIG_DIR"] == "gh"

    for key <-
          ~w(COPILOT_AGENT_SESSION_ID COPILOT_CLI COPILOT_ALLOW_ALL COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_MODEL),
        do: refute(Map.has_key?(actual, key))

    for key <- ~w(COPILOT_ALLOW_ALL COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_MODEL),
        do:
          assert(
            Enum.count(launch.events, fn {:status, event} ->
              String.contains?(event.message, key)
            end) == 1
          )

    assert Environment.clean(env, Paths.copilot_home())["HOME"] == "user"
  end
end

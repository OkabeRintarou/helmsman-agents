defmodule HelmsmanDaemon.Adapters.ClaudeProviderTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Claude
  alias HelmsmanProtocol.ProviderAccount
  @fixtures Path.expand("../../fixtures/claude", __DIR__)
  @cleared ~w(
ANTHROPIC_BASE_URL
ANTHROPIC_UNIX_SOCKET
CLAUDE_CODE_USE_BEDROCK
CLAUDE_CODE_USE_VERTEX
CLAUDE_CODE_USE_FOUNDRY
CLAUDE_CODE_USE_ANTHROPIC_AWS
CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD
CLAUDE_CODE_USE_GATEWAY
CLAUDE_CODE_USE_MANTLE
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_API_KEY
ANTHROPIC_CUSTOM_HEADERS
ANTHROPIC_IDENTITY_TOKEN
ANTHROPIC_IDENTITY_TOKEN_FILE
AWS_BEARER_TOKEN_BEDROCK
ANTHROPIC_AWS_API_KEY
ANTHROPIC_FOUNDRY_API_KEY
ANTHROPIC_FOUNDRY_AUTH_TOKEN
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
ANTHROPIC_CUSTOM_MODEL_OPTION
ANTHROPIC_API_HOST
ANTHROPIC_AWS_BASE_URL
ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_BEDROCK_MANTLE_BASE_URL
ANTHROPIC_FOUNDRY_BASE_URL
ANTHROPIC_GOOGLE_CLOUD_BASE_URL
ANTHROPIC_VERTEX_BASE_URL
ANTHROPIC_ENVIRONMENT_KEY
ANTHROPIC_WORK_SECRET
ANTHROPIC_CUSTOM_MODEL_OPTION_NAME
ANTHROPIC_DEFAULT_FABLE_MODEL_NAME
ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION
ANTHROPIC_BEDROCK_REGION_PREFIX
ANTHROPIC_BEDROCK_SERVICE_TIER
ANTHROPIC_VERTEX_PROJECT_ID
ANTHROPIC_AWS_WORKSPACE_ID
ANTHROPIC_GOOGLE_CLOUD_PROJECT
ANTHROPIC_GOOGLE_CLOUD_WORKSPACE_ID
ANTHROPIC_GOOGLE_CLOUD_LOCATION
ANTHROPIC_FOUNDRY_RESOURCE
CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
CLAUDE_CODE_OAUTH_REFRESH_TOKEN
  )

  defp account do
    %ProviderAccount{
      base_url: "https://account.example/anthropic",
      api_key: "ACCOUNT_SENTINEL",
      models: %{
        "default" => "account-default",
        "opus" => "account-opus",
        "sonnet" => "account-sonnet",
        "haiku" => "account-haiku",
        "fable" => "account-fable",
        "subagent" => "account-subagent"
      }
    }
  end

  defp bound do
    run = spec(1)
    %{run | agent: %{run.agent | provider_account: account(), custom_args: []}}
  end

  test "private override contains every measured variable, mappings and no secret or null", %{
    tmp_dir: dir
  } do
    run = bound()
    assert {:ok, launch} = Claude.prepare(run, dir, dir)
    path = Path.join(dir, "claude-settings.json")
    raw = File.read!(path)
    settings = JSON.decode!(raw)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Enum.sort(Map.keys(settings["env"])) == Enum.sort(@cleared)
    assert settings["model"] == "account-default"
    assert settings["apiKeyHelper"] == "printenv HELMSMAN_PROVIDER_API_KEY"

    expected = %{
      "ANTHROPIC_BASE_URL" => account().base_url,
      "ANTHROPIC_MODEL" => "account-default",
      "ANTHROPIC_DEFAULT_OPUS_MODEL" => "account-opus",
      "ANTHROPIC_DEFAULT_SONNET_MODEL" => "account-sonnet",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "account-haiku",
      "ANTHROPIC_DEFAULT_FABLE_MODEL" => "account-fable",
      "ANTHROPIC_SMALL_FAST_MODEL" => "account-haiku",
      "CLAUDE_CODE_SUBAGENT_MODEL" => "account-subagent"
    }

    assert settings["env"] == Map.merge(Map.new(@cleared, &{&1, ""}), expected)
    refute raw =~ "null"
    refute raw =~ account().api_key
    refute inspect(launch.argv) =~ account().api_key

    assert launch.env == [
             {"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "1"},
             {"HELMSMAN_PROVIDER_API_KEY", account().api_key}
           ]

    index = Enum.find_index(launch.argv, &(&1 == "--mcp-config"))

    assert Enum.slice(launch.argv, index + 2, 5) ==
             ["--setting-sources", "user", "--add-dir=" <> dir, "--settings", path]

    refute Enum.any?(launch.env, fn {key, _} -> key in ["HOME", "CLAUDE_CONFIG_DIR"] end)

    run = %{run | agent: %{run.agent | provider_account: %{account() | models: %{}}}}
    assert {:ok, _} = Claude.prepare(run, dir, dir)
    empty = JSON.decode!(File.read!(path))
    assert empty["model"] == ""
    assert empty["env"]["ANTHROPIC_MODEL"] == ""
    assert empty["env"]["ANTHROPIC_DEFAULT_SONNET_MODEL"] == ""
  end

  test "--settings is removed only for bound accounts, --setting-sources always", %{
    tmp_dir: dir
  } do
    for flag <- ["--settings", "--setting-sources"], inline? <- [true, false] do
      args = if inline?, do: [flag <> "=OVERRIDE_SENTINEL"], else: [flag, "OVERRIDE_SENTINEL"]
      run = bound()
      run = %{run | agent: %{run.agent | custom_args: args ++ ["--max-turns", "1"]}}
      assert {:ok, launch} = Claude.prepare(run, dir, dir)
      refute "OVERRIDE_SENTINEL" in launch.argv
      assert List.last(launch.argv) == "1"
      assert [{:status, %{message: message}}] = launch.events
      assert message =~ flag
      refute message =~ "OVERRIDE_SENTINEL"
    end

    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: ["--settings", "x.json", "--setting-sources=user,project"]
        }
    }

    plain_dir = Paths.private_dir!(Path.join(dir, "plain"))
    assert {:ok, launch} = Claude.prepare(run, plain_dir, dir)
    assert Enum.take(launch.argv, -2) == ["--settings", "x.json"]
    assert Enum.count(launch.argv, &String.starts_with?(&1, "--setting-sources")) == 1
    refute "user,project" in launch.argv
    assert [{:status, %{message: message}}] = launch.events
    assert message =~ "--setting-sources"
    refute message =~ "--settings,"
    assert launch.env == [{"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "1"}]
    refute Enum.any?(launch.env, fn {key, _} -> key == "HELMSMAN_PROVIDER_API_KEY" end)
    refute File.exists?(Path.join(plain_dir, "claude-settings.json"))
  end

  test "recorded helper init succeeds; user credentials, none and missing sources abort" do
    helper = File.read!(Path.join(@fixtures, "provider_helper_init.jsonl")) |> String.trim()
    user = File.read!(Path.join(@fixtures, "provider_user_init.jsonl")) |> String.trim()

    assert {[{:session, _} | _], [], _} =
             Claude.handle_output(:stdout, helper, Claude.init_state(bound()))

    for line <- [
          user,
          JSON.encode!(%{
            "type" => "system",
            "subtype" => "init",
            "session_id" => "s",
            "apiKeySource" => "none"
          }),
          JSON.encode!(%{"type" => "system", "subtype" => "init"})
        ] do
      assert {[], [{:abort, :cli_error, message}], state} =
               Claude.handle_output(:stdout, line, Claude.init_state(bound()))

      assert message =~ "instead of the provider account"

      assert {[], [], ^state} =
               Claude.handle_output(:stdout, ~s({"type":"result","is_error":false}), state)

      assert {[], [], ^state} = Claude.handle_output(:stderr, "later", state)
    end

    for line <- [helper, user] do
      assert {[{:session, _} | _], [], _} =
               Claude.handle_output(:stdout, line, Claude.init_state(spec(1)))
    end
  end

  test "unbound warning lists only names, bound account emits none", %{tmp_dir: dir} do
    run = spec(1)

    env = %{
      "ANTHROPIC_BASE_URL" => "URL_SENTINEL",
      "ANTHROPIC_AUTH_TOKEN" => "TOKEN_SENTINEL",
      "FOO" => "1"
    }

    run = %{run | agent: %{run.agent | custom_args: [], env: env}}
    assert {:ok, launch} = Claude.prepare(run, dir, dir)
    assert [{:status, %{level: :warning, message: message}}] = launch.events
    assert message =~ "ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL"
    for value <- ["URL_SENTINEL", "TOKEN_SENTINEL", "FOO"], do: refute(message =~ value)

    assert {:ok, launch} =
             Claude.prepare(%{run | agent: %{run.agent | provider_account: account()}}, dir, dir)

    assert launch.events == []
  end
end

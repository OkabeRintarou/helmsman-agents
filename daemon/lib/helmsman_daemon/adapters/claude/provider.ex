defmodule HelmsmanDaemon.Adapters.Claude.Provider do
  @moduledoc false
  alias HelmsmanDaemon.AtomicFile

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
  @mappings %{
    "ANTHROPIC_MODEL" => "default",
    "ANTHROPIC_DEFAULT_OPUS_MODEL" => "opus",
    "ANTHROPIC_DEFAULT_SONNET_MODEL" => "sonnet",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "haiku",
    "ANTHROPIC_DEFAULT_FABLE_MODEL" => "fable",
    "ANTHROPIC_SMALL_FAST_MODEL" => "haiku",
    "CLAUDE_CODE_SUBAGENT_MODEL" => "subagent"
  }

  def cleared, do: @cleared

  def prepare(%{provider_account: nil} = agent, _run_dir),
    do: {:ok, [], [], warnings(agent.env)}

  def prepare(%{provider_account: account}, run_dir) do
    path = Path.join(run_dir, "claude-settings.json")
    env = Map.new(@cleared, &{&1, ""})

    env =
      Enum.reduce(@mappings, env, fn {key, alias}, acc ->
        Map.put(acc, key, Map.get(account.models, alias, ""))
      end)

    config = %{
      "env" => Map.put(env, "ANTHROPIC_BASE_URL", account.base_url),
      "model" => Map.get(account.models, "default", ""),
      "apiKeyHelper" => "printenv HELMSMAN_PROVIDER_API_KEY"
    }

    with :ok <- AtomicFile.write(path, JSON.encode!(config)) do
      {:ok, ["--settings", path], [{"HELMSMAN_PROVIDER_API_KEY", account.api_key}], []}
    end
  end

  defp warnings(env) do
    names = env |> Map.keys() |> Enum.filter(&(&1 in @cleared)) |> Enum.sort()

    if names == [],
      do: [],
      else: [
        {:status,
         %{
           level: :warning,
           message:
             "Claude Code settings (~/.claude/settings.json, project .claude/settings*.json) take precedence over these Agent environment variables: " <>
               Enum.join(names, ", ") <> "; bind a provider account to use another provider"
         }}
      ]
  end
end

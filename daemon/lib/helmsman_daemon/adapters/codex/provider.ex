defmodule HelmsmanDaemon.Adapters.Codex.Provider do
  @moduledoc false
  def argv(nil), do: []

  def argv(account) do
    [
      "-c",
      "model_provider=\"helmsman_account\"",
      "-c",
      "model_providers.helmsman_account={name=\"Helmsman provider account\",base_url=" <>
        JSON.encode!(account.base_url) <>
        ",wire_api=\"responses\",env_key=\"HELMSMAN_PROVIDER_API_KEY\"}"
    ]
  end

  def env(nil), do: []
  def env(account), do: [{"HELMSMAN_PROVIDER_API_KEY", account.api_key}]
  def model(%{model: model}) when model not in [nil, ""], do: model
  def model(%{provider_account: nil}), do: nil
  def model(%{provider_account: account}), do: account.models["default"]

  def warnings(%{provider_account: nil, env: env}) do
    names =
      env
      |> Map.keys()
      |> Enum.filter(&(&1 in ~w(OPENAI_BASE_URL OPENAI_API_KEY CODEX_API_KEY)))
      |> Enum.sort()

    if names == [],
      do: [],
      else: [
        {:status,
         %{
           level: :warning,
           message:
             "Codex ignores " <>
               Enum.join(names, ", ") <>
               " when its config selects a model provider; bind a provider account to use another provider"
         }}
      ]
  end

  def warnings(_agent), do: []
end

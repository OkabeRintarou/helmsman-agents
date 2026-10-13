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
        ~s(,wire_api="responses",env_key="HELMSMAN_PROVIDER_API_KEY") <>
        header_config(account.headers) <> "}"
    ]
  end

  def env(nil), do: []

  def env(account) do
    headers =
      Enum.map(Enum.with_index(account.headers, 1), fn {header, index} ->
        {header_env(index), header.value}
      end)

    [{"HELMSMAN_PROVIDER_API_KEY", account.api_key} | headers]
  end

  defp header_config([]), do: ""

  defp header_config(headers) do
    entries =
      headers
      |> Enum.with_index(1)
      |> Enum.map_join(",", fn {header, index} ->
        JSON.encode!(header.name) <> "=" <> JSON.encode!(header_env(index))
      end)

    ",env_http_headers={" <> entries <> "}"
  end

  defp header_env(index), do: "HELMSMAN_PROVIDER_HEADER_#{index}"
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

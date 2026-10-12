defmodule Helmsman.GitHub.Webhooks do
  @moduledoc """
  Receiving webhook deliveries (design decision 9).

  The signature is checked on the raw request body with the App's webhook
  secret in constant time; a verified delivery is recorded by its
  `X-GitHub-Delivery` ID and queued for `Workers.HandleWebhook` in one
  transaction, so a delivery is handled once however often GitHub sends
  it.
  """

  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Delivery
  alias Helmsman.GitHub.Workers.HandleWebhook
  alias Helmsman.Repo
  alias Helmsman.Tx

  @type result ::
          {:ok, :accepted | :duplicate}
          | {:error, :github_not_configured | :bad_request | :invalid_signature}

  @doc """
  Receives a delivery. `headers` maps lowercase header names to values.

    * `{:ok, :accepted}` - recorded and queued (202)
    * `{:ok, :duplicate}` - already received; nothing done (200)
    * `{:error, :bad_request}` - a header is missing or the body is not a
      JSON object (400)
    * `{:error, :invalid_signature}` (401)
    * `{:error, :github_not_configured}` (503)
  """
  @spec receive(binary(), %{optional(String.t()) => String.t()}) :: result()
  def receive(raw_body, headers) when is_binary(raw_body) and is_map(headers) do
    with {:ok, config} <- AppConfig.current(),
         {:ok, delivery_id, event, signature} <- required_headers(headers),
         :ok <- verify(config.webhook_secret, raw_body, signature),
         {:ok, payload} <- decode(raw_body) do
      record(delivery_id, event, payload)
    end
  end

  defp required_headers(headers) do
    case {headers["x-github-delivery"], headers["x-github-event"]} do
      {delivery_id, event} when delivery_id in [nil, ""] or event in [nil, ""] ->
        {:error, :bad_request}

      {delivery_id, event} ->
        {:ok, delivery_id, event, headers["x-hub-signature-256"] || ""}
    end
  end

  @doc "Returns the `X-Hub-Signature-256` value of `body` under `secret`."
  @spec signature(String.t(), binary()) :: String.t()
  def signature(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp verify(secret, body, header) do
    if Plug.Crypto.secure_compare(signature(secret, body), header),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> {:error, :bad_request}
    end
  end

  defp record(delivery_id, event, payload) do
    Tx.run(fn ->
      entry = %{delivery_id: delivery_id, event: event, received_at: DateTime.utc_now(:second)}

      case Repo.insert_all(Delivery, [entry], on_conflict: :nothing) do
        {0, _} ->
          {:ok, :duplicate}

        {1, _} ->
          enqueue(delivery_id, event, payload)
      end
    end)
  end

  defp enqueue(delivery_id, event, payload) do
    job = HandleWebhook.new(%{delivery_id: delivery_id, event: event, payload: payload})
    with {:ok, _job} <- Oban.insert(job), do: {:ok, :accepted}
  end
end

defmodule HelmsmanWeb.AutopilotWebhookPlug do
  @moduledoc """
  Receives `POST /hooks/autopilots/:id` before `Plug.Parsers`
  (`add-autopilots` decision 14): reads the raw body itself (at most 1 MB,
  else 413) and answers in JSON.

    * a missing or wrong `Authorization: Bearer hma_…` token, an unknown
      autopilot or one without a webhook → `401` alike;
    * an `X-Delivery-Id` over 200 bytes or with control characters → `400`;
    * past 10 authenticated requests a minute for the autopilot → `429`
      with `retry-after`, nothing recorded;
    * a new trigger → `202 {"id", "status", "reason"}`; a delivery ID seen
      before → `200` with the original record and `"duplicate": true`;
      a disabled autopilot → `409`.

  Every other request passes through untouched.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.{Autopilots, RateLimit}

  @max_body_bytes 1024 * 1024
  @max_delivery_bytes 200

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["hooks", "autopilots", id]} = conn, _opts) do
    conn |> handle(id) |> halt()
  end

  def call(conn, _opts), do: conn

  defp handle(conn, id) do
    with {:ok, hash} <- authenticate(conn, id),
         {:ok, delivery_id} <- delivery_id(conn),
         :ok <- rate(id),
         {:ok, body, conn} <- body(conn) do
      content_type = conn |> get_req_header("content-type") |> List.first()

      case Autopilots.fire_webhook(id, hash, delivery_id, body, content_type) do
        {:ok, {:duplicate, record}} ->
          json(conn, 200, Map.put(view(record), :duplicate, true))

        {:ok, record} ->
          json(conn, 202, view(record))

        {:error, :unauthorized} ->
          json(conn, 401, %{error: "unauthorized"})

        {:error, :disabled} ->
          json(conn, 409, %{error: "disabled"})

        {:error, :busy} ->
          conn |> put_resp_header("retry-after", "1") |> json(503, %{error: "busy"})
      end
    else
      {:error, :unauthorized} ->
        json(conn, 401, %{error: "unauthorized"})

      {:error, :bad_delivery_id} ->
        json(conn, 400, %{error: "invalid X-Delivery-Id"})

      {:error, :rate_limited, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(1, ceil(retry_after_ms / 1000))))
        |> json(429, %{error: "rate_limited"})

      {:error, :too_large, conn} ->
        json(conn, 413, %{error: "payload too large"})

      {:error, :bad_body, conn} ->
        json(conn, 400, %{error: "unreadable body"})
    end
  end

  defp authenticate(conn, id) do
    token = conn |> get_req_header("authorization") |> List.first() |> bearer()
    Autopilots.authenticate_webhook(id, token)
  end

  defp bearer(value) when is_binary(value) do
    case String.split(value, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: String.trim(token)
      _ -> nil
    end
  end

  defp bearer(nil), do: nil

  defp delivery_id(conn) do
    case get_req_header(conn, "x-delivery-id") do
      [] ->
        {:ok, nil}

      ["" | _] ->
        {:ok, nil}

      [value | _] ->
        if valid_delivery_id?(value), do: {:ok, value}, else: {:error, :bad_delivery_id}
    end
  end

  defp valid_delivery_id?(value) do
    byte_size(value) <= @max_delivery_bytes and String.valid?(value) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp rate(id), do: RateLimit.check_retry(:autopilot_webhook, id)

  defp body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, _reason} -> {:error, :bad_body, conn}
    end
  end

  defp view(record), do: %{id: record.id, status: record.status, reason: record.reason}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

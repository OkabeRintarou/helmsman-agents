defmodule HelmsmanWeb.GitHubWebhookPlug do
  @moduledoc """
  Receives `POST /webhooks/github` before `Plug.Parsers` (design decision
  9): reads the raw body itself (at most 25 MB, else 413), hands it with
  the signature, delivery and event headers to
  `Helmsman.GitHub.receive_webhook/2` and halts with 202 / 200 / 400 / 401
  / 503. Every other request passes through untouched, so the global body
  limits stay as they are.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.GitHub

  @max_body_bytes 25 * 1024 * 1024
  @headers ~w(x-hub-signature-256 x-github-delivery x-github-event)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["webhooks", "github"]} = conn, _opts) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> conn |> respond(GitHub.receive_webhook(body, headers(conn))) |> halt()
      {:more, _partial, conn} -> conn |> send_resp(413, "") |> halt()
      {:error, _reason} -> conn |> send_resp(400, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp headers(conn) do
    for name <- @headers,
        value <- Enum.take(get_req_header(conn, name), 1),
        into: %{},
        do: {name, value}
  end

  defp respond(conn, {:ok, :accepted}), do: send_resp(conn, 202, "")
  defp respond(conn, {:ok, :duplicate}), do: send_resp(conn, 200, "")
  defp respond(conn, {:error, :bad_request}), do: send_resp(conn, 400, "")
  defp respond(conn, {:error, :invalid_signature}), do: send_resp(conn, 401, "")
  defp respond(conn, {:error, :github_not_configured}), do: send_resp(conn, 503, "")
end

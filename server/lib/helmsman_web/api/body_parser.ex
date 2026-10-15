defmodule HelmsmanWeb.API.BodyParser do
  @moduledoc """
  `Plug.Parsers` for the endpoint. On `/api` paths a body that cannot be
  parsed (invalid JSON, too large) is rendered as JSON whatever the
  `Accept` header: the error is raised again in a `Plug.Conn.WrapperError`
  whose connection has the `json` format, so the endpoint renders it with
  `HelmsmanWeb.ErrorJSON` (`add-rest-api` decision 5).
  """

  @behaviour Plug

  alias Plug.Conn.WrapperError

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  # `HelmsmanWeb.API.SpecController.import/2` reads its archive body itself,
  # after authentication and authorization (`add-spec-workflow` decision 21).
  @impl true
  def call(
        %Plug.Conn{method: "POST", path_info: ["api", "v1", "w", _, "tasks", _, "spec", "import"]} =
          conn,
        _opts
      ),
      do: conn

  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    error in [Plug.Parsers.ParseError, Plug.Parsers.RequestTooLargeError] ->
      if api?(conn) do
        conn = Phoenix.Controller.put_format(conn, "json")
        WrapperError.reraise(conn, :error, error, __STACKTRACE__)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp api?(%Plug.Conn{path_info: ["api" | _rest]}), do: true
  defp api?(_conn), do: false
end

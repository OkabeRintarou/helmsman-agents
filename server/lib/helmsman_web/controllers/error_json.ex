defmodule HelmsmanWeb.ErrorJSON do
  @moduledoc """
  Renders errors of JSON requests (see config/config.exs) with the REST
  error body of `HelmsmanWeb.ErrorMapper` (`add-rest-api` decision 5):
  `{"error", "message", "detail"}`, including what Phoenix raises before
  the router, such as a body that is not valid JSON (400 `invalid_json`)
  or too large (413 `payload_too_large`).
  """

  alias HelmsmanWeb.ErrorMapper

  @codes %{
    400 => "bad_request",
    401 => "unauthorized",
    403 => "forbidden",
    404 => "not_found",
    406 => "not_acceptable",
    413 => "payload_too_large",
    415 => "unsupported_media_type",
    429 => "rate_limited"
  }

  def render(template, assigns) do
    ErrorMapper.body(code(template, assigns[:reason]))
  end

  defp code(_template, %Plug.Parsers.ParseError{}), do: "invalid_json"
  defp code(_template, %Plug.Parsers.RequestTooLargeError{}), do: "payload_too_large"

  defp code(template, _reason) do
    status = template |> String.split(".") |> hd() |> String.to_integer()
    Map.get(@codes, status, if(status >= 500, do: "internal", else: "bad_request"))
  end
end

defmodule HelmsmanWeb.API.Accepts do
  @moduledoc """
  `Phoenix.Controller.accepts/2` for the REST API: an `Accept` header
  none of `formats` satisfies is still 406, but rendered with the REST
  error body (`not_acceptable`) whatever the header asked for
  (`add-rest-api` decision 5): the error is raised again in a
  `Plug.Conn.WrapperError` whose connection has the `json` format, so the
  endpoint renders it with `HelmsmanWeb.ErrorJSON`.

      plug HelmsmanWeb.API.Accepts, ["json"]
  """

  @behaviour Plug

  alias Plug.Conn.WrapperError

  @impl true
  def init(formats) when is_list(formats), do: formats

  @impl true
  def call(conn, formats) do
    Phoenix.Controller.accepts(conn, formats)
  rescue
    error in Phoenix.NotAcceptableError ->
      conn = Phoenix.Controller.put_format(conn, "json")
      WrapperError.reraise(conn, :error, error, __STACKTRACE__)
  end
end

defmodule HelmsmanWeb.NotFoundError do
  @moduledoc """
  Raised for resources that do not exist or that the user may not see;
  both render the same 404 page.
  """

  defexception message: "not found", plug_status: 404
end

defmodule HelmsmanWeb.ForbiddenError do
  @moduledoc """
  Raised when the user may see a page's existence but not open it (for
  example `/admin/github` for users who are not instance administrators);
  renders the 403 page.
  """

  defexception message: "forbidden", plug_status: 403
end

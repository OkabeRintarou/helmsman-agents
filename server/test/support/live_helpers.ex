defmodule HelmsmanWeb.LiveHelpers do
  @moduledoc """
  Helpers for LiveView tests of pages that coalesce reloads
  (`HelmsmanWeb.Throttle`, 500ms by default).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions, only: [flunk: 1]

  @doc "Polls `fun` every 50ms until it returns a truthy value (at most ~3s)."
  def eventually(fun, tries \\ 60) do
    if fun.() do
      true
    else
      if tries == 0, do: flunk("condition never held")
      Process.sleep(50)
      eventually(fun, tries - 1)
    end
  end
end

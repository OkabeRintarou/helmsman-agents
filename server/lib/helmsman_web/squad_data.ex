defmodule HelmsmanWeb.SquadData do
  @moduledoc """
  The squad domain functions the web layer uses (add-squads-autopilots-ui D13): thin
  wrappers of `Helmsman.Squads` (views as its `get/2`, with `can_manage`;
  `create/2` and `update/3` add `cancelled_runs`).
  """

  alias Helmsman.Squads

  defdelegate list(scope), to: Squads
  defdelegate get(scope, name), to: Squads
  defdelegate create(scope, attrs), to: Squads
  defdelegate update(scope, name, attrs), to: Squads
  defdelegate disable(scope, name), to: Squads
  defdelegate enable(scope, name), to: Squads

  @doc "`%{name => :ok | {:skipped, reason, refused}}`; empty when the scope may not read squads."
  def availability(scope) do
    case Squads.availability(scope) do
      {:ok, map} -> map
      _error -> %{}
    end
  end
end

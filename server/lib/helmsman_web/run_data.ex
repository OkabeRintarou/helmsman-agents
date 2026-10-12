defmodule HelmsmanWeb.RunData do
  @moduledoc """
  The web layer's single entry for reading agents, runtimes and runs (add-agents-runs-ui
  D2). Pages and components call this module, so a domain signature change touches one
  module.

  Placeholders (marked `PLACEHOLDER(domain-request-1 Rn)`) stand in for the read functions of
  `reviews/domain-request-1.md` that are not merged yet; tasks 5.2 replaces them with
  plain delegations.
  """
  alias Helmsman.Daemons

  @online_after_seconds 120

  @doc "The user's daemons with `online` (R8)."
  # PLACEHOLDER(domain-request-1 R8): `Daemons.list_own/1` returns `online`.
  def daemons(scope) do
    now = DateTime.utc_now()
    Enum.map(Daemons.list_own(scope), &Map.put_new(&1, :online, online?(&1, now)))
  end

  defp online?(%{revoked: true}, _now), do: false
  defp online?(%{last_seen_at: nil}, _now), do: false

  defp online?(%{last_seen_at: at}, now),
    do: DateTime.diff(now, at, :second) < @online_after_seconds
end

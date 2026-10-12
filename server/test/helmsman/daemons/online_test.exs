defmodule Helmsman.Daemons.OnlineTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures

  alias Helmsman.Daemons

  test "a daemon is online when not revoked and seen within the threshold" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    now = Daemons.now()
    threshold = Daemons.online_threshold_seconds()
    assert threshold == 120

    cases = [
      {"fresh", %{last_seen_at: DateTime.add(now, -60)}, true},
      {"recent", %{last_seen_at: DateTime.add(now, 10 - threshold)}, true},
      {"stale", %{last_seen_at: DateTime.add(now, -(threshold + 1))}, false},
      {"never", %{last_seen_at: nil}, false},
      {"revoked", %{last_seen_at: now, revoked_at: now}, false}
    ]

    for {name, attrs, _online} <- cases, do: daemon_fixture(user, Map.put(attrs, :name, name))

    online = Map.new(Daemons.list_own(scope), &{&1.name, &1.online})
    assert online == Map.new(cases, fn {name, _attrs, expected} -> {name, expected} end)
  end
end

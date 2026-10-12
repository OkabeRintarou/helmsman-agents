defmodule Helmsman.GitHub.PruneDeliveriesTest do
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  alias Helmsman.GitHub.Delivery
  alias Helmsman.GitHub.Workers.PruneDeliveries

  test "deletes deliveries older than 7 days, keeps the rest" do
    now = DateTime.utc_now(:second)

    Repo.insert_all(Delivery, [
      %{delivery_id: "old", event: "ping", received_at: DateTime.add(now, -8, :day)},
      %{delivery_id: "recent", event: "ping", received_at: DateTime.add(now, -6, :day)}
    ])

    assert :ok = perform_job(PruneDeliveries, %{})

    assert Repo.all(
             from(d in Delivery, select: d.delivery_id, where: d.delivery_id in ["old", "recent"])
           ) == ["recent"]
  end
end

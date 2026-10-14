defmodule Helmsman.Daemons.VendorTest do
  # update-actor-icons 3.5: daemon-runtimes「运行时的厂商」(D10).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Daemons, Events}
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Daemons.Workers.MarkOffline
  alias HelmsmanProtocol.{CLI, Machine, Report}

  setup do
    alice = user_fixture()
    ws7 = workspace_fixture(alice)
    ws9 = workspace_fixture(alice)
    {daemon, _token} = daemon_fixture(alice, %{workspace_ids: [ws7.id, ws9.id]})

    for ws <- [ws7, ws9], do: :ok = Events.subscribe(Events.topic(:workspace, ws.id))
    %{ws7: ws7, ws9: ws9, daemon: daemon}
  end

  defp cli(vendor, attrs \\ %{}) do
    Map.merge(
      %CLI{
        provider: :claude,
        version: "3.2.1",
        models: ["opus-4"],
        efforts: ["high"],
        available: true,
        vendor: vendor
      },
      attrs
    )
  end

  defp register(ctx, clis, kind \\ :join) do
    report =
      case kind do
        :join ->
          %Report.Join{
            protocol: HelmsmanProtocol.version(),
            machine: machine(),
            clis: clis,
            max_concurrency: 6,
            active_runs: []
          }

        :sync ->
          %Report.Sync{machine: machine(), clis: clis, max_concurrency: 6}
      end

    assert {:ok, _runtimes} = Daemons.register(ctx.daemon.id, ctx.daemon.auth_epoch, report)
  end

  defp machine, do: %Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"}

  defp vendors(ctx),
    do:
      Repo.all(
        from(r in Runtime,
          where: r.daemon_id == ^ctx.daemon.id,
          order_by: r.workspace_id,
          select: {r.workspace_id, r.provider, r.vendor}
        )
      )

  defp assert_notified_each_once do
    assert_receive {:runtimes_changed}
    assert_receive {:runtimes_changed}
    refute_receive {:runtimes_changed}, 50
  end

  test "a reported vendor is kept on the CLI's runtime in every served workspace", ctx do
    register(ctx, [cli("zai")])
    assert vendors(ctx) == [{ctx.ws7.id, "claude", "zai"}, {ctx.ws9.id, "claude", "zai"}]
    assert_notified_each_once()

    register(ctx, [cli("zai")])
    refute_receive {:runtimes_changed}, 50
  end

  test "only the vendor changing (sync): cleared, and each workspace is told", ctx do
    register(ctx, [cli("zai")])
    assert_notified_each_once()

    register(ctx, [cli(nil)], :sync)
    assert vendors(ctx) == [{ctx.ws7.id, "claude", nil}, {ctx.ws9.id, "claude", nil}]
    assert_notified_each_once()

    register(ctx, [cli("kimi")], :sync)
    assert [{_, _, "kimi"}, {_, _, "kimi"}] = vendors(ctx)
    assert_notified_each_once()
  end

  test "an unknown key of the right format is stored as none", ctx do
    register(ctx, [cli("newco")])
    assert [{_, _, nil}, {_, _, nil}] = vendors(ctx)
  end

  test "an old daemon (no field) and an unavailable CLI store none", ctx do
    register(ctx, [cli("zai")])
    old = Map.delete(cli(nil), :vendor)
    register(ctx, [old], :sync)
    assert [{_, _, nil}, {_, _, nil}] = vendors(ctx)

    register(ctx, [cli("zai")], :sync)

    unavailable =
      cli("zai", %{version: nil, available: false, unavailable_reason: "not logged in"})

    register(ctx, [unavailable], :sync)
    assert [{_, _, nil}, {_, _, nil}] = vendors(ctx)
  end

  test "going offline after the grace period keeps the vendor", ctx do
    register(ctx, [cli("zai")])
    assert_notified_each_once()

    old = DateTime.add(Daemons.now(), -3_600)
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [last_seen_at: old])
    assert :ok = MarkOffline.perform(%Oban.Job{args: %{}})

    assert_notified_each_once()

    assert Repo.all(from(r in Runtime, where: r.daemon_id == ^ctx.daemon.id, select: r.status)) ==
             ["offline", "offline"]

    assert [{_, _, "zai"}, {_, _, "zai"}] = vendors(ctx)
  end

  test "a CLI no longer detected keeps its vendor", ctx do
    register(ctx, [cli("zai")])
    codex = cli("openai", %{provider: :codex})
    register(ctx, [codex], :sync)

    assert Enum.sort(vendors(ctx)) ==
             Enum.sort([
               {ctx.ws7.id, "claude", "zai"},
               {ctx.ws9.id, "claude", "zai"},
               {ctx.ws7.id, "codex", "openai"},
               {ctx.ws9.id, "codex", "openai"}
             ])
  end
end

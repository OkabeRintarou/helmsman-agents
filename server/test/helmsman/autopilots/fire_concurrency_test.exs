defmodule Helmsman.Autopilots.FireConcurrencyTest do
  # add-autopilots 3.1: interleavings fixed with test-hook barriers, each
  # side on a connection of its own (specs/autopilot-execution "同时到来的
  # 两次触发", "过期的失效来源").
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AutopilotsFixtures

  alias Helmsman.{Autopilots, CommittedData, Repo}
  alias Helmsman.Autopilots.{Autopilot, Clock, Fire, Record}
  alias Helmsman.Tasks.Task, as: TaskRow

  @moduletag timeout: 60_000
  @wait 5_000

  setup do
    ctx = CommittedData.unboxed(fn -> autopilots_fixture() end)

    on_exit(fn ->
      CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id])
    end)

    ctx
  end

  # Runs `fun` on its own connection; with `pause`, stops the first time
  # the test hook `pause` is reached until `continue/1`.
  defp side(fun, pause \\ nil, now \\ nil) do
    parent = self()

    task =
      Task.async(fn -> CommittedData.unboxed(fn -> run_side(fun, parent, pause, now) end) end)

    assert_receive {:backend, pid, backend}, @wait
    %{task: task, pid: pid, backend: backend}
  end

  defp run_side(fun, parent, pause, now) do
    if now, do: Clock.put(now)
    send(parent, {:backend, self(), CommittedData.backend_pid()})
    if pause, do: install_pause(parent, pause)
    fun.()
  end

  defp install_pause(parent, pause) do
    Process.put(:helmsman_test_hook, fn
      ^pause -> pause_once(parent)
      _other -> :ok
    end)
  end

  defp pause_once(parent) do
    if Process.get(:paused) == nil do
      Process.put(:paused, true)
      send(parent, {:paused, self()})
      receive do: (:continue -> :ok)
    end
  end

  defp await_paused(%{pid: pid}), do: assert_receive({:paused, ^pid}, @wait)
  defp continue(%{pid: pid}), do: send(pid, :continue)
  defp result(%{task: task}), do: Task.await(task, @wait)

  defp records(id),
    do:
      CommittedData.unboxed(fn ->
        Repo.all(from(r in Record, where: r.autopilot_id == ^id, order_by: r.id))
      end)

  test "a manual trigger and a webhook at once: one started, one skipped / overlap, one task",
       ctx do
    view = CommittedData.unboxed(fn -> autopilot_fixture(ctx.alice_scope) end)

    {:ok, %{token: token}} =
      CommittedData.unboxed(fn -> Autopilots.enable_webhook(ctx.alice_scope, view.id) end)

    manual = side(fn -> Autopilots.run_now(ctx.alice_scope, view.id) end, {:locked, :manual})
    await_paused(manual)

    hook =
      side(fn ->
        {:ok, hash} = Autopilots.authenticate_webhook(view.id, token)
        Autopilots.fire_webhook(view.id, hash, "d-1", "", nil)
      end)

    CommittedData.await_lock_wait(hook.backend)
    continue(manual)

    assert {:ok, %Record{status: :started}} = result(manual)
    assert {:ok, %Record{status: :skipped, reason: "overlap"}} = result(hook)

    assert [:started, :skipped] = Enum.map(records(view.id), & &1.status)

    assert CommittedData.unboxed(fn ->
             Repo.aggregate(
               from(t in TaskRow, where: t.workspace_id == ^ctx.workspace.id),
               :count
             )
           end) == 1
  end

  test "a stale empty source: bob enables it first; no record, still enabled, bob's schedule",
       ctx do
    now = ~U[2026-10-14 09:10:00.000000Z]
    at = ~U[2026-10-14 09:00:00.000000Z]

    view =
      CommittedData.unboxed(fn ->
        Clock.put(~U[2026-10-14 08:00:00Z])
        view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})

        Repo.update_all(from(a in Autopilot, where: a.id == ^view.id),
          set: [initiator_user_id: nil]
        )

        view
      end)

    stale = side(fn -> Fire.request(view.id, {:schedule, at}) end, {:accept, :schedule}, now)
    await_paused(stale)

    enabled =
      side(fn -> Autopilots.enable(ctx.bob_scope, view.id) end, nil, now)

    assert {:ok, %{enabled: true}} = result(enabled)
    continue(stale)
    assert {:ok, :noop} = result(stale)

    assert records(view.id) == []

    row = CommittedData.unboxed(fn -> Repo.get!(Autopilot, view.id) end)
    assert {row.enabled, row.initiator_user_id} == {true, ctx.bob.id}
    assert row.next_run_at == ~U[2026-10-15 09:00:00.000000Z]
  end
end

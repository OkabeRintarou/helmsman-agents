defmodule Helmsman.AgentDesigns.LifecycleTest do
  # add-agent-conversation 3.4: stopping, discarding, queue timeout,
  # expiry and deletion (decision 10).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentDesignsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Expire, Sweep}
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = design_fixture()
    Map.put(ctx, :id, start_design!(ctx.alice_scope).id)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp set_design(id, changes),
    do: Repo.update_all(from(d in AgentDesign, where: d.id == ^id), set: changes)

  test "stopping a running turn (scenario); the next message works at once", ctx do
    run = run_turn!(ctx, ctx.id)

    assert {:ok, %{current_run: nil}} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    assert %Run{status: :cancelling} = Repo.get!(Run, run.id)
    assert %{role: :system, code: "stopped", run_id: run_id} = List.last(messages!(ctx.id))
    assert run_id == run.id

    assert {:ok, %{current_run: %{status: :queued}}} =
             AgentDesigns.send(ctx.alice_scope, ctx.id, "next")

    count = length(messages!(ctx.id))
    end_and_settle!(Repo.get!(Run, run.id), :cancelled)
    assert length(messages!(ctx.id)) == count
  end

  test "stopping a queued turn cancels its run; nothing to stop is unchanged", ctx do
    run = current_run!(ctx.id)
    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    assert %Run{status: :cancelled} = Repo.get!(Run, run.id)

    count = length(messages!(ctx.id))
    assert {:ok, %{current_run: nil}} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    assert length(messages!(ctx.id)) == count
  end

  test "discarding: discarded, the turn stopped, nothing created (scenario)", ctx do
    run = run_turn!(ctx, ctx.id)
    agents = Repo.aggregate(Actor, :count)

    assert {:ok, %{status: :discarded, current_run: nil}} =
             AgentDesigns.discard(ctx.alice_scope, ctx.id)

    assert %Run{status: :cancelling} = Repo.get!(Run, run.id)
    assert design!(ctx.id).closed_at
    assert Repo.aggregate(Actor, :count) == agents
    assert AgentDesigns.discard(ctx.alice_scope, ctx.id) == {:error, :design_closed}
  end

  test "a turn queued for 10 minutes is cancelled with a message (scenario)", ctx do
    run = current_run!(ctx.id)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: ago(599)])
    perform_job(Sweep, %{})
    assert %Run{status: :queued} = Repo.get!(Run, run.id)

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: ago(601)])
    perform_job(Sweep, %{})

    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, run.id)
    assert %{role: :system, code: "queue_timeout"} = List.last(messages!(ctx.id))
    assert design!(ctx.id).current_run_id == nil
    assert AgentDesigns.settle(run.id) == {:ok, :skipped}
  end

  test "a claimed turn is not cancelled by the sweep", ctx do
    run = run_turn!(ctx, ctx.id)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: ago(900)])
    assert AgentDesigns.sweep_queued() == 0
    assert design!(ctx.id).current_run_id == run.id
  end

  test "idle for 7 days: expired, a new conversation can start (scenario)", ctx do
    run = run_turn!(ctx, ctx.id)
    set_design(ctx.id, last_activity_at: ago(6 * 86_400))
    perform_job(Expire, %{})
    assert design!(ctx.id).status == :open

    set_design(ctx.id, last_activity_at: ago(7 * 86_400 + 60))
    perform_job(Expire, %{})

    assert %AgentDesign{status: :expired, current_run_id: nil, closed_at: %DateTime{}} =
             design!(ctx.id)

    assert %Run{status: :cancelling} = Repo.get!(Run, run.id)
    assert %{id: new_id} = start_design!(ctx.alice_scope)
    assert new_id != ctx.id
  end

  test "a user no longer a member: expired", ctx do
    Repo.delete_all(
      from(m in Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
      )
    )

    assert %{expired: 1} = AgentDesigns.expire()
    assert design!(ctx.id).status == :expired
  end

  test "closed over 30 days ago: deleted with its messages, its runs stay", ctx do
    run = current_run!(ctx.id)
    {:ok, _} = AgentDesigns.discard(ctx.alice_scope, ctx.id)
    set_design(ctx.id, closed_at: ago(29 * 86_400))
    assert %{deleted: 0} = AgentDesigns.expire()

    set_design(ctx.id, closed_at: ago(31 * 86_400))
    assert %{deleted: 1} = AgentDesigns.expire()

    refute Repo.get(AgentDesign, ctx.id)

    assert Repo.aggregate(from(m in AgentDesignMessage, where: m.design_id == ^ctx.id), :count) ==
             0

    assert Repo.get(Run, run.id)
  end

  test "both jobs are in the Oban cron configuration" do
    crontab =
      :helmsman
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _other -> nil
      end)

    assert {"* * * * *", Sweep} in crontab
    assert Enum.any?(crontab, &match?({"20 * * * *", Expire}, &1))
  end
end

defmodule Helmsman.Squads.DelegateDoneTest do
  # add-squads 4.2: a delegated run that ends wakes the current leader
  # (squad-dispatch "委派完成"; dependency-dispatch "不受依赖约束的触发";
  # decision 9).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.AgentsFixtures

  alias Helmsman.{Agents, Links, Runs, Squads, Tasks}
  alias Helmsman.Runs.{Retry, Run, Spec}
  alias Helmsman.Runs.Workers.SideEffect

  @summary "Settings page done, tests pass."

  setup do
    ctx = squads_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team", start: false})
    {:ok, _} = Tasks.transition(ctx.alice_scope, task.ident, :in_progress)
    Repo.delete_all(Oban.Job)

    leader_run =
      run_fixture(ctx.lead, %{
        task_id: task.id,
        status: :succeeded,
        squad_id: ctx.squad.id,
        root_initiator_user_id: ctx.alice.id,
        causal_agent_ids: [ctx.lead.id],
        finished_at: DateTime.utc_now()
      })

    Map.merge(ctx, %{task: task, leader_run: leader_run, daemon: daemon_of(ctx.fe)})
  end

  defp delegated(ctx, extra \\ []) do
    trigger =
      trigger("delegated", ctx.workspace, ctx.alice, ctx.fe, %{
        "by_actor_id" => ctx.lead.id,
        "squad_id" => ctx.squad.id,
        "leader_run_id" => ctx.leader_run.id,
        "instructions" => "Implement the settings page",
        "causal_agent_ids" => [ctx.lead.id, ctx.fe.id]
      })

    run_fixture(ctx.fe, %{
      task_id: ctx.task.id,
      status: :running,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.utc_now(),
      started_at: DateTime.utc_now(),
      root_initiator_user_id: ctx.alice.id,
      causal_agent_ids: [ctx.lead.id, ctx.fe.id],
      capabilities: ["read", "write_task"],
      triggers: [trigger | Keyword.get(extra, :more, [])]
    })
  end

  defp effect(run), do: perform_job(SideEffect, %{run_id: run.id, kind: "delegate_done"})

  defp leader_runs(ctx, agent \\ nil) do
    agent = agent || ctx.lead

    Repo.all(
      from(r in Run,
        where: r.task_id == ^ctx.task.id and r.agent_id == ^agent.id and r.status == :queued
      )
    )
  end

  defp woken?(run),
    do:
      Repo.exists?(
        from(j in Oban.Job,
          where: j.args["run_id"] == ^run.id and j.args["kind"] == "delegate_done"
        )
      )

  test "the member's run succeeded: the leader as the squad, with its output", ctx do
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :succeeded, %{summary: @summary})
    assert_enqueued(worker: SideEffect, args: %{run_id: run.id, kind: "delegate_done"})

    assert :ok = effect(run)

    assert [
             %Run{squad_id: squad_id, root_initiator_user_id: initiator, triggers: [trigger]} =
               woke
           ] =
             leader_runs(ctx)

    assert {squad_id, initiator} == {ctx.squad.id, ctx.alice.id}
    fe_id = ctx.fe.id
    run_id = run.id

    assert %{
             "kind" => "delegate_done",
             "by_actor_id" => ^fe_id,
             "delegated_run_id" => ^run_id,
             "member" => "keel/fe",
             "status" => "succeeded",
             "squad_id" => ^squad_id
           } = trigger

    woke = woke |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
    {:ok, spec} = Spec.build(woke, "hmr_" <> String.duplicate("a", 52), "https://hm.test")

    assert spec.prompt =~
             "- The run of keel/fe (run #{run.id}) that you delegated #{ctx.task.ident} to " <>
               "has ended: succeeded.\nIts final output:\n> #{@summary}"

    # Once only.
    Repo.update_all(from(r in Run, where: r.id == ^woke.id), set: [status: :queued])
    assert :ok = effect(run)
    assert [%Run{triggers: [_]}] = leader_runs(ctx)
  end

  test "failed and retried automatically: not woken; the retry carries the trigger", ctx do
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :failed, %{failure_reason: :provider_network})
    refute woken?(run)

    assert {:ok, :retried} = Retry.perform(run.id)
    assert [%Run{triggers: triggers}] = leader_runs(ctx, ctx.fe)
    assert Enum.any?(triggers, &(&1["kind"] == "delegated"))
  end

  test "failed, the retry not requeued (agent disabled): woken then", ctx do
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :failed, %{failure_reason: :provider_network})
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/fe")

    assert {:ok, :skipped} = Retry.perform(run.id)
    assert woken?(run)
    assert :ok = effect(run)
    assert [_] = leader_runs(ctx)
  end

  test "failed without a retry: woken with the reason", ctx do
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :failed, %{failure_reason: :cli_error})
    assert :ok = effect(run)

    assert [%Run{triggers: [%{"status" => "failed", "failure_reason" => "cli_error"}]}] =
             leader_runs(ctx)
  end

  test "stopped by a person: not woken", ctx do
    run = delegated(ctx)
    {:ok, _} = Runs.cancel(ctx.alice_scope, run.id)
    finish!(ctx.fe, run.id, :cancelled)
    refute woken?(run)
  end

  test "stopped by the system (the member archived): woken", ctx do
    run = delegated(ctx)
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/fe")
    finish!(ctx.fe, run.id, :cancelled)
    assert woken?(run)
    assert :ok = effect(run)
    assert [_] = leader_runs(ctx)
  end

  test "the member moved the task to done: not woken", ctx do
    run = delegated(ctx)
    {scope, _token} = run_scope_fixture(run)
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :done)
    finish!(ctx.fe, run.id, :succeeded, %{summary: @summary})
    assert :ok = effect(run)
    assert leader_runs(ctx) == []
  end

  test "the leader changed: the new leader is woken", ctx do
    lead2 =
      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/lead2",
        runtime_id: ctx.runtime_id,
        access: "workspace"
      })

    run = delegated(ctx)
    {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})
    finish!(ctx.fe, run.id, :succeeded)
    assert :ok = effect(run)

    lead2 = agent_actor(ctx.workspace, lead2.name)
    assert [%Run{squad_id: squad_id, causal_agent_ids: chain}] = leader_runs(ctx, lead2)
    assert squad_id == ctx.squad.id
    assert lead2.id in chain
  end

  test "reassigned or the squad disabled: not woken", ctx do
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :succeeded)
    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
    assert :ok = effect(run)
    assert leader_runs(ctx) == []
  end

  test "a merged manual trigger: still one wake-up", ctx do
    manual = trigger("manual", ctx.workspace, ctx.carol, ctx.fe)
    run = delegated(ctx, more: [manual])
    finish!(ctx.fe, run.id, :succeeded)
    assert :ok = effect(run)
    assert [%Run{triggers: [%{"kind" => "delegate_done"}]}] = leader_runs(ctx)
  end

  describe "several sources (code-review-2)" do
    # A run of the leader as the squad that delegated, for `user`.
    defp leader_run(ctx, user, squad_id \\ nil) do
      run_fixture(ctx.lead, %{
        task_id: ctx.task.id,
        status: :succeeded,
        squad_id: squad_id || ctx.squad.id,
        root_initiator_user_id: user.id,
        causal_agent_ids: [ctx.lead.id],
        finished_at: DateTime.utc_now()
      })
    end

    defp entry(ctx, leader_run, user, squad_id \\ nil) do
      trigger("delegated", ctx.workspace, user, ctx.fe, %{
        "by_actor_id" => ctx.lead.id,
        "squad_id" => squad_id || ctx.squad.id,
        "leader_run_id" => leader_run.id,
        "causal_agent_ids" => [ctx.lead.id, ctx.fe.id]
      })
    end

    defp member_run(ctx, entries) do
      run_fixture(ctx.fe, %{
        task_id: ctx.task.id,
        status: :succeeded,
        summary: "done",
        finished_at: DateTime.utc_now(),
        triggers: entries
      })
    end

    defp wake_sources(ctx) do
      for r <-
            Repo.all(
              from(r in Run, where: r.task_id == ^ctx.task.id and r.status in [:queued, :claimed])
            ),
          t <- r.triggers,
          t["kind"] == "delegate_done",
          do: {t["initiator_user_id"], t["leader_run_id"]}
    end

    test "two leader runs merged into one member run: two sources, once each", ctx do
      {carol_run, bob_run} = {leader_run(ctx, ctx.carol), leader_run(ctx, ctx.bob)}
      run = member_run(ctx, [entry(ctx, carol_run, ctx.carol), entry(ctx, bob_run, ctx.bob)])

      assert :ok = effect(run)

      assert Enum.sort(wake_sources(ctx)) ==
               Enum.sort([{ctx.carol.id, carol_run.id}, {ctx.bob.id, bob_run.id}])

      assert [%Run{triggers: [_, _]} = woke] = leader_runs(ctx)

      {:ok, spec} =
        Spec.build(
          %{woke | status: :claimed},
          "hmr_" <> String.duplicate("a", 52),
          "https://hm.test"
        )

      assert length(String.split(spec.prompt, "that you delegated")) == 2

      # Again, and again once the wake-up is claimed: nothing more.
      assert :ok = effect(run)
      Repo.update_all(from(r in Run, where: r.id == ^woke.id), set: [status: :claimed])
      assert :ok = effect(run)
      assert length(wake_sources(ctx)) == 2
    end

    test "the first source loses its right: the second one carries the wake-up", ctx do
      {carol_run, bob_run} = {leader_run(ctx, ctx.carol), leader_run(ctx, ctx.bob)}
      run = member_run(ctx, [entry(ctx, carol_run, ctx.carol), entry(ctx, bob_run, ctx.bob)])
      assert :ok = effect(run)

      Repo.update_all(
        from(m in Helmsman.Workspaces.Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
        ),
        set: [role: :viewer]
      )

      [woke] = leader_runs(ctx)
      assert woke.id in claim!(ctx.lead)
      claimed = Repo.get!(Run, woke.id)
      assert claimed.status == :claimed
      assert [%{"kind" => "delegate_done", "initiator_user_id" => bob}] = claimed.triggers
      assert bob == ctx.bob.id
      assert claimed.root_initiator_user_id == ctx.bob.id
    end

    test "the same pair twice wakes once", ctx do
      first = leader_run(ctx, ctx.alice)
      run = member_run(ctx, [entry(ctx, first, ctx.alice), entry(ctx, first, ctx.alice)])
      assert :ok = effect(run)
      assert wake_sources(ctx) == [{ctx.alice.id, first.id}]
    end

    test "another squad's wake-up does not hold back this squad's", ctx do
      other =
        squad_fixture(ctx.alice_scope, %{
          name: "api-team",
          leader: "keel/lead",
          members: [%{name: "keel/fe"}]
        })

      other_actor = agent_actor(ctx.workspace, "api-team")
      {mine, theirs} = {leader_run(ctx, ctx.alice), leader_run(ctx, ctx.alice, other.id)}

      run =
        member_run(ctx, [entry(ctx, theirs, ctx.alice, other.id), entry(ctx, mine, ctx.alice)])

      Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id),
        set: [assignee_id: other_actor.id]
      )

      assert :ok = effect(run)
      assert wake_sources(ctx) == [{ctx.alice.id, theirs.id}]

      Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id),
        set: [assignee_id: ctx.squad_actor.id]
      )

      assert :ok = effect(run)

      assert Enum.sort(wake_sources(ctx)) ==
               Enum.sort([{ctx.alice.id, theirs.id}, {ctx.alice.id, mine.id}])
    end
  end

  test "a task blocked by its dependencies: the wake-up is queued", ctx do
    bos1 = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, ctx.task.ident, bos1.ident, "depends_on")
    run = delegated(ctx)
    finish!(ctx.fe, run.id, :succeeded)
    assert :ok = effect(run)
    assert [%Run{status: :queued}] = leader_runs(ctx)
  end
end

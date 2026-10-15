defmodule Helmsman.Runs.SquadRunsTest do
  # add-squads 2.3: what a run as a squad leader may do and its auto-claim,
  # and the claim check dropping triggers one by one (squad-dispatch
  # "leader 运行的能力与开工", "小队运行的复核"; run-lifecycle "领取与启动前的
  # 复核"; decisions 7, 10).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.{Runs, Squads, Tasks}
  alias Helmsman.Runs.{Run, SideEffects}
  alias Helmsman.Tasks.Task, as: TaskRow

  @alice 1
  @bob 2
  @carol 3
  @lead 100
  @fe 101
  @other 102
  @squad 5
  @squad_actor 500

  describe "the check, trigger by trigger (pure)" do
    defp t(kind, user, extra \\ %{}) do
      Map.merge(
        %{
          "kind" => kind,
          "by_actor_id" => 1000 + user,
          "initiator_user_id" => user,
          "causal_agent_ids" => [@lead],
          "at" => "2026-10-12T00:00:00Z"
        },
        extra
      )
    end

    defp delegated(user), do: t("delegated", user, %{"squad_id" => @squad})
    defp auto_retry, do: %{"kind" => "retry", "retry_of" => 3, "auto" => true}

    defp run(agent, squad_id, triggers) do
      %Run{
        id: 9,
        agent_id: agent,
        squad_id: squad_id,
        runtime_id: 50,
        task_id: 70,
        lane: :work,
        status: :queued,
        triggers: triggers,
        root_initiator_user_id: hd(triggers)["initiator_user_id"] || @alice,
        causal_agent_ids: [agent]
      }
    end

    defp locked(agent, opts) do
      squad =
        Map.merge(
          %{actor_id: @squad_actor, disabled: false, leader_agent_id: @lead, member_ids: [@fe]},
          Map.new(Keyword.get(opts, :squad, []))
        )

      %{
        members:
          Keyword.get(opts, :members, %{@alice => :owner, @bob => :member, @carol => :member}),
        agent: %Actor{id: agent, kind: :agent, owner_id: @alice},
        profile: %AgentProfile{actor_id: agent, runtime_id: 50, access: "workspace"},
        task: %TaskRow{id: 70, status: :in_progress, assignee_id: Keyword.get(opts, :assignee)},
        runtime: %Runtime{id: 50},
        squads: if(Keyword.get(opts, :squad_gone), do: %{}, else: %{@squad => squad})
      }
    end

    # {name, agent, squad_id, triggers, locked opts, expected}
    @cases [
      {"leader run, assigned to the squad", @lead, @squad, [{"assign", @alice}],
       [assignee: @squad_actor], :ok},
      {"leader run, reassigned to the leader itself", @lead, @squad, [{"assign", @alice}],
       [assignee: @lead], {:obsolete, :reassigned}},
      {"leader run, squad disabled", @lead, @squad, [{"assign", @alice}],
       [assignee: @squad_actor, squad: [disabled: true]], {:obsolete, :squad_disabled}},
      {"leader run, squad gone", @lead, @squad, [{"mention", @alice}],
       [assignee: @squad_actor, squad_gone: true], {:obsolete, :squad_disabled}},
      {"leader run, leader changed", @lead, @squad, [{"assign", @alice}],
       [assignee: @squad_actor, squad: [leader_agent_id: @other]], {:obsolete, :not_leader}},
      {"leader run, mention after reassignment", @lead, @squad, [{"mention", @carol}],
       [assignee: @bob], :ok},
      {"leader run, delegate_done after reassignment", @lead, @squad,
       [{"delegate_done", @alice}, :auto_retry], [assignee: @bob], {:obsolete, :reassigned}},
      {"leader run, only the leader is checked", @lead, @squad, [{"assign", @alice}],
       [assignee: @squad_actor, members: %{@alice => :owner}], :ok},
      {"delegated, still a member", @fe, nil, [:delegated], [assignee: @squad_actor], :ok},
      {"delegated, removed from the squad", @fe, nil, [:delegated],
       [assignee: @squad_actor, squad: [member_ids: []]], {:obsolete, :reassigned}},
      {"delegated, task reassigned", @fe, nil, [:delegated], [assignee: @bob],
       {:obsolete, :reassigned}},
      {"delegated, squad disabled", @fe, nil, [:delegated],
       [assignee: @squad_actor, squad: [disabled: true]], {:obsolete, :reassigned}},
      {"delegated, the source left", @fe, nil, [:delegated],
       [assignee: @squad_actor, members: %{@bob => :member}], :unauthorized},
      {"[delegated, manual] removed: the manual one", @fe, nil, [:delegated, {"manual", @carol}],
       [assignee: @squad_actor, squad: [member_ids: []]], {:pruned, ["manual"], @carol}},
      {"[assign, manual] reassigned: the manual one", @lead, nil,
       [{"assign", @alice}, {"manual", @carol}], [assignee: @bob], {:pruned, ["manual"], @carol}},
      {"[manual by bob, assign] bob gone and reassigned", @lead, nil,
       [{"manual", @bob}, {"assign", @alice}], [assignee: @carol, members: %{@alice => :owner}],
       :unauthorized},
      {"[assign] reassigned", @lead, nil, [{"assign", @alice}], [assignee: @carol],
       {:obsolete, :reassigned}},
      {"[assign by bob, manual] bob gone", @lead, nil, [{"assign", @bob}, {"manual", @alice}],
       [assignee: @lead, members: %{@alice => :owner}], {:pruned, ["manual"], @alice}},
      {"answer bound to the squad, unchanged", @fe, nil,
       [{"answer", @alice, %{"bound_assignee_id" => @squad_actor}}], [assignee: @squad_actor],
       :ok},
      {"answer bound to the squad, reassigned", @fe, nil,
       [{"answer", @alice, %{"bound_assignee_id" => @squad_actor}}], [assignee: @bob],
       {:obsolete, :reassigned}},
      {"older answer bound to the run's agent", @lead, nil,
       [{"answer", @alice, %{"assignee_bound" => true}}], [assignee: @bob],
       {:obsolete, :reassigned}},
      {"unbound answer", @lead, nil, [{"answer", @alice, %{"assignee_bound" => false}}],
       [assignee: @bob], :ok}
    ]

    for {name, agent, squad_id, triggers, opts, expected} <- @cases do
      @agent agent
      @squad_id squad_id
      @triggers triggers
      @opts opts
      @expected expected
      test name do
        triggers =
          Enum.map(@triggers, fn
            :delegated -> delegated(@alice)
            :auto_retry -> auto_retry()
            {kind, user} -> t(kind, user)
            {kind, user, extra} -> t(kind, user, extra)
          end)

        result = Runs.revalidate(run(@agent, @squad_id, triggers), locked(@agent, @opts))

        case @expected do
          {:pruned, kinds, root} ->
            assert {:pruned, changes} = result
            assert Enum.map(changes.triggers, & &1["kind"]) == kinds
            assert changes.root_initiator_user_id == root

          expected ->
            assert result == expected
        end
      end
    end
  end

  describe "claiming and starting (database)" do
    setup do
      ctx = squads_fixture()
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
      [run] = runs_of(task.id)
      daemon = daemon_of(ctx.lead)
      Map.merge(ctx, %{task: task, run: run, daemon: daemon})
    end

    defp claim(ctx) do
      {:ok, specs} = Runs.claim(daemon_ctx(ctx.daemon), "https://hm.test")
      specs
    end

    defp reload(run), do: Repo.get!(Run, run.id)

    test "a leader run has read, write_task, create_tasks, delegate and orchestrate", ctx do
      refute "create_tasks" in profile(ctx.lead).capabilities
      assert [spec] = claim(ctx)
      assert spec.run_id == ctx.run.id

      assert reload(ctx.run).capabilities == [
               "read",
               "write_task",
               "create_tasks",
               "delegate",
               "orchestrate"
             ]

      own = run_fixture(ctx.lead, %{task_id: ctx.task.id, status: :queued})
      assert own.squad_id == nil

      assert Runs.capabilities(profile(ctx.lead), ctx.task, own.triggers, nil) == [
               "read",
               "write_task"
             ]
    end

    test "the leader run starts the task as the leader; the squad stays the assignee", ctx do
      [_spec] = claim(ctx)
      assert {:ok, :proceed} = Runs.starting(daemon_ctx(ctx.daemon), ctx.run.id)
      assert {:ok, :claimed} = SideEffects.auto_claim(ctx.run.id)

      task = Repo.get!(TaskRow, ctx.task.id)
      assert task.status == :in_progress
      assert task.assignee_id == ctx.squad_actor.id

      {:ok, %{events: events}} = Tasks.get(ctx.alice_scope, ctx.task.ident)

      assert %{to_status: :in_progress, auto: true, actor: %{name: "keel/lead"}} =
               List.last(events)
    end

    test "a delegated run does not start the task", ctx do
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :cancelled])

      run =
        run_fixture(ctx.fe, %{
          task_id: ctx.task.id,
          status: :running,
          started_at: DateTime.utc_now(),
          triggers: [
            trigger("delegated", ctx.workspace, ctx.alice, ctx.fe, %{"squad_id" => ctx.squad.id})
          ]
        })

      assert {:ok, :skipped} = SideEffects.auto_claim(run.id)
      assert Repo.get!(TaskRow, ctx.task.id).status == :new
    end

    test "claiming: a disabled squad, then the same at starting", ctx do
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(ctx.run)

      # Starting: claimed first, then the squad disabled.
      {:ok, _} = Squads.enable(ctx.alice_scope, "web-team")
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"})
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "web-team"})
      run = Enum.find(runs_of(ctx.task.id), &(&1.status == :queued and &1.squad_id))
      [_spec] = claim(ctx)
      assert reload(run).status == :claimed

      Repo.update_all(from(a in Actor, where: a.id == ^ctx.squad_actor.id),
        set: [disabled_at: DateTime.utc_now(:second)]
      )

      assert {:ok, {:abort, "obsolete"}} = Runs.starting(daemon_ctx(ctx.daemon), run.id)
      assert %Run{status: :failed, failure_reason: :obsolete} = reload(run)
    end

    test "claiming: the leader changed while queued", ctx do
      Repo.update_all(from(s in Helmsman.Squads.Squad, where: s.id == ^ctx.squad.id),
        set: [leader_agent_id: ctx.fe.id]
      )

      assert claim(ctx) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(ctx.run)
    end

    test "claiming: reassigned to the leader itself", ctx do
      Repo.update_all(from(t in TaskRow, where: t.id == ^ctx.task.id),
        set: [assignee_id: ctx.lead.id]
      )

      assert claim(ctx) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(ctx.run)
    end

    test "claiming and starting agree on a delegated run whose member left", ctx do
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :cancelled])

      delegated =
        run_fixture(ctx.fe, %{
          task_id: ctx.task.id,
          triggers: [
            trigger("delegated", ctx.workspace, ctx.alice, ctx.fe, %{"squad_id" => ctx.squad.id})
          ]
        })

      {:ok, _} =
        Squads.update(ctx.alice_scope, "web-team", %{members: [%{name: "keel/review"}]})

      assert claim(ctx) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(delegated)

      claimed =
        run_fixture(ctx.fe, %{
          task_id: ctx.task.id,
          status: :claimed,
          daemon_id: ctx.daemon.id,
          claimed_at: DateTime.utc_now(),
          triggers: [
            trigger("delegated", ctx.workspace, ctx.alice, ctx.fe, %{"squad_id" => ctx.squad.id})
          ]
        })

      assert {:ok, {:abort, "obsolete"}} = Runs.starting(daemon_ctx(ctx.daemon), claimed.id)
      assert %Run{status: :failed, failure_reason: :obsolete} = reload(claimed)
    end
  end
end

defmodule Helmsman.AutopilotsTest do
  # add-autopilots 1.3: configuration, authorization source, reading and
  # notifications (specs/autopilots).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Agents
  alias Helmsman.Autopilots
  alias Helmsman.Autopilots.{Autopilot, Clock}
  alias Oban.Job

  setup do
    ctx = autopilots_fixture()

    # alice's owner_only agent keel/triage on her runtime.
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/triage",
      runtime_id: profile(ctx.agent).runtime_id,
      access: "owner_only"
    })

    Map.put(ctx, :triage, agent_actor(ctx.workspace, "keel/triage"))
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{
        name: "nightly-triage",
        agent: "keel/triage",
        project: ctx.project.key,
        mode: "create_task",
        title_template: "Triage {{date}}",
        instructions: "Triage the new tasks.",
        cron: "0 9 * * 1-5",
        timezone: "Asia/Shanghai"
      },
      extra
    )
  end

  describe "configuration" do
    test "a daily triage autopilot: enabled, next weekday 09:00 Shanghai, alice its source",
         ctx do
      # Friday 2026-10-16 10:00 Shanghai: the next is Monday 09:00.
      Clock.put(~U[2026-10-16 02:00:00Z])
      assert {:ok, view} = Autopilots.create(ctx.alice_scope, attrs(ctx))

      assert view.enabled
      assert view.next_run_at == ~U[2026-10-19 01:00:00.000000Z]
      assert view.initiator == %{name: ctx.alice_scope.actor.name}
      assert view.created_by == %{name: ctx.alice_scope.actor.name}
      assert view.agent == %{name: "keel/triage", kind: "agent"}
      assert view.mode == :create_task
      assert view.warnings == []

      assert [%Job{args: %{"autopilot_id" => id, "at" => at}}] =
               all_enqueued(worker: Helmsman.Autopilots.Workers.Fire)

      assert id == view.id
      assert at == "2026-10-19T01:00:00.000000Z"
    end

    test "create_task without a project and template: both field errors, nothing written", ctx do
      assert {:error, changeset} =
               Autopilots.create(
                 ctx.alice_scope,
                 attrs(ctx, %{project: nil, title_template: nil})
               )

      assert %{project: [_], title_template: [_]} = errors_on(changeset)
      assert Repo.aggregate(Autopilot, :count) == 0
    end

    test "every field error at once", ctx do
      assert {:error, changeset} =
               Autopilots.create(ctx.alice_scope, %{
                 name: "",
                 agent: "nobody",
                 mode: "sometimes",
                 instructions: "",
                 cron: "*/2 * * * *",
                 timezone: "Mars/Olympus",
                 overlap: "maybe"
               })

      errors = errors_on(changeset)

      for field <- [:name, :agent, :mode, :instructions, :cron, :timezone, :overlap],
          do: assert(Map.has_key?(errors, field), "#{field}")
    end

    test "a run-only autopilot may not target a squad", ctx do
      squad = squad_fixture(ctx.alice_scope, %{leader: "keel/dev"})

      assert {:error, changeset} =
               Autopilots.create(
                 ctx.alice_scope,
                 attrs(ctx, %{mode: "run_only", agent: squad.name, project: nil})
               )

      assert %{agent: ["must be a managed agent"]} = errors_on(changeset)
    end

    test "people, external agents and archived agents are not targets", ctx do
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/triage")

      for {target, message} <- [
            {ctx.alice_scope.actor.name, "must be a managed agent"},
            {"keel/triage", "is archived"},
            {"helmsman", "must be a managed agent"}
          ] do
        assert {:error, changeset} =
                 Autopilots.create(ctx.alice_scope, attrs(ctx, %{agent: target}))

        assert %{agent: [^message]} = errors_on(changeset)
      end
    end

    test "a blank title template in create_task mode is a field error, never an exception",
         ctx do
      for title <- ["   ", "\t\n"] do
        assert {:error, changeset} =
                 Autopilots.create(
                   ctx.alice_scope,
                   attrs(ctx, %{agent: "keel/dev", title_template: title})
                 )

        assert %{title_template: ["can't be blank"]} = errors_on(changeset)
      end

      assert Repo.aggregate(Autopilot, :count) == 0

      view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/dev"})

      assert {:error, changeset} =
               Autopilots.update(ctx.alice_scope, view.id, %{title_template: " \n "})

      assert %{title_template: [_]} = errors_on(changeset)

      # A run-only autopilot may have a blank one; switching it to
      # create_task needs one.
      run_only =
        autopilot_fixture(ctx.alice_scope, %{
          agent: "keel/dev",
          mode: "run_only",
          project: nil,
          title_template: "  "
        })

      assert autopilot_row(run_only).title_template == nil

      assert {:error, changeset} =
               Autopilots.update(ctx.alice_scope, run_only.id, %{
                 mode: "create_task",
                 project: ctx.project.key,
                 title_template: "\t"
               })

      assert %{title_template: [_]} = errors_on(changeset)
      assert autopilot_row(run_only).mode == :run_only
    end

    test "instructions are measured in bytes", ctx do
      text = String.duplicate("😀", 5000)

      assert {:error, changeset} =
               Autopilots.create(ctx.alice_scope, attrs(ctx, %{instructions: text}))

      assert %{instructions: [_]} = errors_on(changeset)
    end

    test "names differing only in case are refused", ctx do
      autopilot_fixture(ctx.alice_scope, %{name: "Nightly"})

      assert {:error, changeset} =
               Autopilots.create(ctx.alice_scope, attrs(ctx, %{name: "nightly"}))

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "the 101st autopilot of a workspace: limit_reached", ctx do
      now = DateTime.utc_now()

      rows =
        for i <- 1..100 do
          %{
            workspace_id: ctx.workspace.id,
            name: "bulk-#{i}",
            agent_id: ctx.agent.id,
            mode: :run_only,
            instructions: "x",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Autopilot, rows)

      assert Autopilots.create(ctx.alice_scope, attrs(ctx, %{agent: "keel/dev"})) ==
               {:error, :limit_reached}
    end

    test "a stale lock_version is refused; without one the last write wins", ctx do
      view = autopilot_fixture(ctx.alice_scope)

      assert {:ok, %{lock_version: 2}} =
               Autopilots.update(ctx.alice_scope, view.id, %{instructions: "A", lock_version: 1})

      assert Autopilots.update(ctx.alice_scope, view.id, %{instructions: "B", lock_version: 1}) ==
               {:error, :stale}

      assert {:ok, %{instructions: "C"}} =
               Autopilots.update(ctx.alice_scope, view.id, %{instructions: "C"})
    end

    test "preview gives the next five times or field errors" do
      assert {:ok, [_, _, _, _, _]} = Autopilots.preview("0 9 * * *", "UTC")
      assert {:error, changeset} = Autopilots.preview("*/2 * * * *", "UTC")
      assert %{cron: ["too_frequent"]} = errors_on(changeset)
    end
  end

  describe "who may manage" do
    test "an admin may not borrow alice's owner_only agent", ctx do
      assert Autopilots.create(ctx.carol_scope, attrs(ctx)) == {:error, :forbidden}
    end

    test "a viewer may read but not create", ctx do
      view = autopilot_fixture(ctx.alice_scope)
      {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
      assert {:ok, [%{id: id, permissions: perms}]} = Autopilots.list(viewer)
      assert id == view.id
      assert perms == %{manage: false, run: false, disable: false}
      assert {:ok, _} = Autopilots.history(viewer, view.id)
      assert Autopilots.create(viewer, attrs(ctx, %{agent: "keel/dev"})) == {:error, :forbidden}
    end

    test "a run token may not create, change or disable", ctx do
      view = autopilot_fixture(ctx.alice_scope)
      run = run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "create_tasks"]})
      {scope, _token} = run_scope_fixture(run)

      assert Autopilots.create(scope, attrs(ctx, %{agent: "keel/dev"})) == {:error, :forbidden}
      assert Autopilots.update(scope, view.id, %{instructions: "x"}) == {:error, :forbidden}
      assert Autopilots.disable(scope, view.id) == {:error, :forbidden}
      assert Autopilots.run_now(scope, view.id) == {:error, :forbidden}
    end
  end

  describe "authorization source" do
    test "whoever saves it last becomes its source; the creator stays", ctx do
      view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/dev"})
      assert {:ok, view} = Autopilots.update(ctx.bob_scope, view.id, %{instructions: "Changed"})
      assert view.initiator == %{name: ctx.bob_scope.actor.name}
      assert view.created_by == %{name: ctx.alice_scope.actor.name}
      assert autopilot_row(view).initiator_user_id == ctx.bob.id
    end

    test "bob may not change an autopilot whose target he may not trigger", ctx do
      view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/triage"})

      assert Autopilots.update(ctx.bob_scope, view.id, %{instructions: "@C do X"}) ==
               {:error, :forbidden}

      assert Autopilots.update(ctx.bob_scope, view.id, %{agent: "keel/dev"}) ==
               {:error, :forbidden}
    end
  end

  describe "reading and notifications" do
    test "no read returns the webhook token or its hash", ctx do
      view = autopilot_fixture(ctx.alice_scope)

      {:ok, %{token: token, autopilot: enabled}} =
        Autopilots.enable_webhook(ctx.alice_scope, view.id)

      hash = autopilot_row(view).webhook_token_hash
      assert is_binary(hash)

      {:ok, list} = Autopilots.list(ctx.alice_scope)
      {:ok, got} = Autopilots.get(ctx.alice_scope, view.id)
      {:ok, updated} = Autopilots.update(ctx.alice_scope, view.id, %{instructions: "x"})

      for value <- [list, got, updated, enabled] do
        dump = inspect(value, limit: :infinity, printable_limit: :infinity)
        refute dump =~ token
        refute dump =~ inspect(hash)
        refute dump =~ "webhook_token_hash"
      end

      assert got.webhook == %{
               enabled: true,
               url: "http://localhost:4000/hooks/autopilots/#{view.id}"
             }
    end

    test "warnings: the target archived", ctx do
      view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/triage"})
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/triage")
      {:ok, view} = Autopilots.get(ctx.alice_scope, view.id)
      assert view.enabled
      assert :agent_archived in view.warnings
    end

    test "warnings: the source may no longer trigger the target", ctx do
      view = autopilot_fixture(ctx.bob_scope, %{agent: "keel/dev"})
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: "owner_only"})
      {:ok, view} = Autopilots.get(ctx.alice_scope, view.id)
      assert view.warnings == [:unauthorized]
    end

    test "changes are announced after the commit, never on rollback", ctx do
      Helmsman.Events.subscribe(Autopilots.topic(ctx.workspace.id))
      view = autopilot_fixture(ctx.alice_scope)
      id = view.id
      assert_receive {:autopilot, ^id}

      {:ok, record} = Autopilots.run_now(ctx.alice_scope, id)
      record_id = record.id
      assert_receive {:autopilot_run, ^id, ^record_id}

      # A failing save rolls back: nothing is announced.
      assert {:error, _} = Autopilots.update(ctx.alice_scope, id, %{cron: "*/2 * * * *"})
      refute_receive {:autopilot, ^id}

      Process.put(:helmsman_test_hook, fn
        {:accept, :manual} -> raise "boom"
        _ -> :ok
      end)

      assert_raise RuntimeError, fn -> Autopilots.run_now(ctx.alice_scope, id) end
      Process.delete(:helmsman_test_hook)
      refute_receive {:autopilot_run, ^id, _}
      refute_receive {:autopilot, ^id}
    end
  end
end

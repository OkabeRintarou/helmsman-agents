defmodule Helmsman.Squads.OrchestrationWriteTest do
  # improve-squad-leader-orchestration 1.4: squad-orchestration 「编排写入」
  # 「编排的审计」, run-tokens 「按能力限制」, task-links 「运行中的关联限制」
  # (decisions 4, 6, 7).
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Links, Repo, Squads, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.Run

  setup do
    ctx = orchestration_fixture()
    # The callback run of the leader on the first step (root: the epic).
    {scope, run} = leader_run(ctx, ctx.lead, ctx.s1)

    Map.merge(ctx, %{
      scope: scope,
      run: run,
      carol_name: human_actor(ctx.workspace, ctx.carol).name
    })
  end

  defp notes(task),
    do:
      Repo.all(
        from(f in Entry,
          join: a in Actor,
          on: a.id == f.author_id,
          where: f.task_id == ^task.id and a.kind == :system,
          order_by: f.seq
        )
      )

  defp runs(task),
    do:
      Repo.all(from(r in Run, where: r.task_id == ^task.id and r.status in [:queued, :deferred]))

  defp prefix(ctx),
    do:
      "Orchestration by keel/lead (squad web-team, run #{ctx.run.id} on #{ctx.s1.ident}, " <>
        "root #{ctx.epic.ident}): "

  describe "update_task" do
    test "assigning an unassigned step starts the member as the run", ctx do
      assert {:ok, task} =
               Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: true})

      assert task.assignee.name == "keel/qa"

      assert [
               %Run{
                 root_initiator_user_id: initiator,
                 causal_agent_ids: chain,
                 triggers: [trigger]
               }
             ] =
               runs(ctx.s3)

      assert initiator == ctx.alice.id
      assert Enum.sort(chain) == Enum.sort([ctx.lead.id, ctx.qa.id])
      assert %{"kind" => "assign", "by_actor_id" => by} = trigger
      assert by == ctx.lead.id

      assert [%Entry{content: content, dispatch: [%{"result" => "queued"}]}] = notes(ctx.s3)
      assert content == prefix(ctx) <> "assigned #{ctx.s3.ident} to keel/qa and started it."
    end

    test "not started, and unassigning", ctx do
      {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
      {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{"assignee" => ""})

      assert Enum.map(notes(ctx.s3), & &1.content) == [
               prefix(ctx) <> "assigned #{ctx.s3.ident} to keel/qa (not started).",
               prefix(ctx) <> "unassigned #{ctx.s3.ident}."
             ]

      assert runs(ctx.s3) == []
    end

    test "the same assignee: nothing happens, no note", ctx do
      assert {:ok, _} =
               Tasks.update(ctx.scope, ctx.s2.ident, %{assignee: "keel/review", start: true})

      assert runs(ctx.s2) == []
      assert notes(ctx.s2) == []
    end

    test "other fields", ctx do
      assert {:error, {:orchestration, :fields, ["assignee", "start"]}} =
               Tasks.update(ctx.scope, ctx.s2.ident, %{title: "PPU only"})

      assert Repo.reload!(ctx.s2).title == "PPU"
    end

    test "a step held by someone outside the squad", ctx do
      {:ok, _} =
        Tasks.update(ctx.alice_scope, ctx.s2.ident, %{assignee: ctx.carol_name, start: false})

      assert {:error, {:orchestration, :outside_assignee, ident, name}} =
               Tasks.update(ctx.scope, ctx.s2.ident, %{assignee: "keel/qa"})

      assert {ident, name} == {ctx.s2.ident, ctx.carol_name}
    end

    test "a disabled agent's step may be handed over", ctx do
      outsider =
        Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{access: "workspace"})

      {:ok, _} =
        Tasks.update(ctx.alice_scope, ctx.s2.ident, %{assignee: outsider.name, start: false})

      {:ok, _} = Helmsman.Agents.disable(ctx.alice_scope, outsider.name)

      assert {:ok, _} =
               Tasks.update(ctx.scope, ctx.s2.ident, %{assignee: "keel/qa", start: false})
    end

    test "new assignees: not a non-member, the leader or the squad", ctx do
      for name <- [ctx.carol_name, "keel/lead", "web-team", "keel/dev"] do
        assert {:error, {:orchestration, :not_member, ^name, "web-team"}} =
                 Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: name})
      end

      # A person member is fine.
      bob = human_actor(ctx.workspace, ctx.bob).name
      assert {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: bob})
    end

    test "the root itself", ctx do
      assert {:error, {:orchestration, :root, ident}} =
               Tasks.update(ctx.scope, ctx.epic.ident, %{assignee: "keel/qa"})

      assert ident == ctx.epic.ident
    end

    test "a disabled squad, or no longer the leader", ctx do
      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/dev"})

      assert {:error, {:orchestration, :not_leader, "web-team"}} =
               Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa"})

      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead"})
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

      assert {:error, {:orchestration, :squad_disabled, "web-team"}} =
               Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa"})

      assert notes(ctx.s3) == []
    end

    test "a run without orchestrate keeps the old rule and error", ctx do
      {scope, _} = leader_run(ctx, ctx.fe, ctx.s1, squad: false)
      assert {:error, :forbidden} = Tasks.update(scope, ctx.s3.ident, %{assignee: "keel/qa"})
    end

    test "transitions, feedback and specs of other tasks stay out of reach", ctx do
      assert {:error, :forbidden} = Tasks.transition(ctx.scope, ctx.s2.ident, :in_progress)
      assert {:error, :forbidden} = Feedback.add(ctx.scope, ctx.s2.ident, %{content: "go"})
    end
  end

  describe "run-tokens: the leader run on the epic" do
    test "a step it created: assign yes, title no", ctx do
      assert {:ok, _} = Tasks.update(ctx.lead_scope, ctx.s3.ident, %{assignee: "keel/fe"})

      assert {:error, {:orchestration, :fields, _}} =
               Tasks.update(ctx.lead_scope, ctx.s3.ident, %{title: "x"})
    end
  end

  describe "links" do
    test "depends_on between steps, noted on the from end", ctx do
      assert {:ok, _} = Links.add(ctx.scope, ctx.s3.ident, ctx.s2.ident, "depends_on")

      assert [%Entry{content: content}] = notes(ctx.s3)
      assert content == prefix(ctx) <> "#{ctx.s3.ident} now depends on #{ctx.s2.ident}."

      # Again: nothing changes, no note.
      assert {:ok, _} = Links.add(ctx.scope, ctx.s3.ident, ctx.s2.ident, "depends_on")
      assert length(notes(ctx.s3)) == 1

      # An assign run of the dependent waits.
      {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa"})
      assert [%Run{status: :deferred}] = runs(ctx.s3)

      assert {:ok, _} = Links.remove(ctx.scope, ctx.s3.ident, ctx.s2.ident, "depends_on")

      assert List.last(notes(ctx.s3)).content =~
               "#{ctx.s3.ident} no longer depends on #{ctx.s2.ident}."
    end

    test "replaces, and one end outside", ctx do
      assert {:error, {:orchestration, :link_type}} =
               Links.add(ctx.scope, ctx.s3.ident, ctx.s2.ident, "replaces")

      other = task_fixture(ctx.alice_scope, ctx.project.key)

      assert {:error, {:orchestration, :outside, ident, _root}} =
               Links.add(ctx.scope, ctx.s3.ident, other.ident, "depends_on")

      assert ident == other.ident
      assert notes(ctx.s3) == []
    end

    test "without orchestrate: forbidden as before", ctx do
      {scope, _} = leader_run(ctx, ctx.fe, ctx.s1, squad: false)
      assert {:error, :forbidden} = Links.add(scope, ctx.s3.ident, ctx.s2.ident, "depends_on")
    end
  end

  test "notes are the system's and trigger nothing", ctx do
    {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
    assert [%Entry{source_run_id: nil, mentions: []}] = notes(ctx.s3)
    assert runs(ctx.s3) == []
  end
end

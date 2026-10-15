defmodule Helmsman.Runs.PromptSpecTest do
  # add-spec-workflow 2.4: spec-dispatch 「运行提示词里的规格」「规格角色与唤醒的
  # 提示词」「leader 提示词的规格流程」 (decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.Runs.{Prompt, Run, Spec}
  alias Helmsman.{Squads, Tasks, TaskSpecs}
  alias HelmsmanProtocol.RunSpec

  @token "hmr_" <> String.duplicate("a", 52)

  setup do
    ctx = specs_fixture()
    Repo.delete_all(from(r in Run, where: r.status == :queued))
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    Map.merge(ctx, %{ident: ctx.task.ident, lead_scope: lead})
  end

  defp prompt(run) do
    {:ok, %RunSpec{prompt: prompt}} =
      Spec.build(Repo.get!(Run, run.id), @token, "https://hm.test")

    prompt
  end

  # A claimed run of `agent` on `task` with `triggers`.
  defp run(agent, task, triggers, attrs \\ %{}) do
    run_fixture(
      agent,
      Map.merge(%{task_id: task.id, status: :claimed, triggers: triggers}, attrs)
    )
  end

  defp entry(ctx, kind, extra, by \\ nil) do
    by = by || human_actor(ctx.workspace, ctx.alice)
    Map.merge(trigger(kind, ctx.workspace, ctx.alice, ctx.fe, %{"by_actor_id" => by.id}), extra)
  end

  defp alice(ctx), do: human_actor(ctx.workspace, ctx.alice).name

  describe "运行提示词里的规格" do
    test "no spec: the prompt is unchanged", ctx do
      run = run(ctx.fe, ctx.task, [entry(ctx, "manual", %{})])
      text = prompt(run)
      refute text =~ "spec"
      refute text =~ "Spec"

      {:ok, profile} = Helmsman.Agents.execution_config(ctx.fe.id)

      base = %{
        agent: ctx.fe,
        profile: profile,
        workspace: ctx.workspace,
        task: ctx.task,
        names: %{human_actor(ctx.workspace, ctx.alice).id => alice(ctx)},
        retried: %{},
        resume?: false
      }

      assert Prompt.build(run, base) ==
               Prompt.build(run, Map.put(base, :spec, TaskSpecs.prompt_context(run, ctx.task)))
    end

    test "an empty spec", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
      text = ctx.fe |> run(ctx.task, [entry(ctx, "manual", %{})]) |> prompt()
      change = String.downcase(ctx.ident)

      assert text =~
               "started you manually.\nSpec: #{ctx.ident} needs a spec (change #{change}, no version " <>
                 "yet). See get_spec(\"#{ctx.ident}\") and the Specs section of helmsman://workflow.\n"
    end

    test "in progress and pending approval", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2, change_id: "add-x")
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
      text = ctx.fe |> run(ctx.task, [entry(ctx, "manual", %{})]) |> prompt()

      assert text =~
               "Spec: #{ctx.ident} has a spec in review (change add-x, latest version 2, valid, " <>
                 "0 unresolved P1/P2 issue(s), 1 pending review(s)). Read it with " <>
                 "get_spec(\"#{ctx.ident}\") and list_spec_reviews(\"#{ctx.ident}\").\n"

      {:ok, _} = TaskSpecs.cancel_request(ctx.alice_scope, ctx.ident, %{reviewer: "keel/review"})
      {:ok, _} = TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 2, summary: "ok"})
      text = ctx.fe |> run(ctx.task, [entry(ctx, "manual", %{})]) |> prompt()
      assert text =~ "has a spec in pending approval ("
      assert text =~ ". Version 2 is waiting for a person's approval.\n"
    end

    test "final, abandoned, and in a resumed session", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 3)
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 3, wake: false})
      run = run(ctx.agent, ctx.task, [entry(ctx, "manual", %{})])

      assert prompt(run) =~
               "The spec of #{ctx.ident} is final (version 3). Read it with " <>
                 "get_spec(\"#{ctx.ident}\") and implement according to it.\n"

      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :succeeded,
        session_id: "s-1",
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

      resumed = prompt(run)
      assert resumed =~ ~r/\AWhy you were started:\n.*\nThe spec of #{ctx.ident} is final/
      {:ok, _} = TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "x"})
      {:ok, _} = TaskSpecs.abandon(ctx.alice_scope, ctx.ident, %{reason: "y"})
      assert prompt(run) =~ "Spec: the spec of #{ctx.ident} was abandoned; do not rely on it."
    end

    test "the epic's final spec", ctx do
      epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})
      child = task_fixture(ctx.alice_scope, ctx.project.key, %{epic: epic.ident})
      spec_fixture(ctx.alice_scope, epic.ident, versions: 2)
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, epic.ident, %{version: 2, wake: false})

      text = ctx.fe |> run(child, [entry(ctx, "manual", %{})]) |> prompt()

      assert text =~
               "The epic #{epic.ident} has a final spec (version 2). Read it with " <>
                 "get_spec(\"#{epic.ident}\")."
    end

    test "the spec line stays within 512 bytes" do
      line =
        Prompt.spec_line("LONGKEY123-99999", %{
          status: :pending_approval,
          change_id: "a" <> String.duplicate("b", 63),
          latest_version: 200,
          final_version: nil,
          proposal_version: 200,
          valid: false,
          unresolved: 999,
          pending: 999
        })

      assert byte_size(line) <= 512
    end
  end

  describe "规格角色与唤醒的提示词" do
    test "a person's review request quotes the instructions and points at the diff", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)

      {:ok, _} =
        TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"], %{note: "重点看并发"})

      [run] = Repo.all(from(r in Run, where: r.agent_id == ^ctx.review.id))
      text = prompt(run)

      assert text =~
               "- #{alice(ctx)} asked you to review version 2 of the spec of #{ctx.ident}. Read it with " <>
                 ~s[get_spec("#{ctx.ident}") and diff_spec("#{ctx.ident}", 1, 2), then submit your ] <>
                 "review with submit_spec_review"

      assert text =~ "Do not change the spec, the code or the task status."
      assert text =~ "> 重点看并发"
    end

    test "delegated roles", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 1)
      lead = ctx.lead

      for {role, expected} <- [
            {"draft", "Your job: draft the spec in the OpenSpec structure"},
            {"revise", "Your job: revise the spec after review. Reply to every unresolved issue"},
            {"review",
             "Your job: review version 1 of the spec of #{ctx.ident}. Read it with get_spec"}
          ] do
        trigger =
          entry(
            ctx,
            "delegated",
            %{
              "squad_id" => ctx.squad.id,
              "spec_role" => role,
              "spec_version" => 1,
              "instructions" => "Go"
            },
            lead
          )

        text = ctx.fe |> run(ctx.task, [trigger]) |> prompt()
        assert text =~ "leading the squad web-team, delegated #{ctx.ident} to you:\n> Go\n"
        assert text =~ expected
        Repo.delete_all(from(r in Run, where: r.agent_id == ^ctx.fe.id and r.status == :claimed))
      end
    end

    test "woken by a review and by decisions", ctx do
      bob = human_actor(ctx.workspace, ctx.bob)

      reviewed =
        entry(
          ctx,
          "spec_reviewed",
          %{
            "review" => 1,
            "version" => 2,
            "verdict" => "fail",
            "counts" => %{"P1" => 1, "P2" => 1, "P3" => 1}
          },
          bob
        )

      approved = entry(ctx, "spec_decided", %{"decision" => "approved", "version" => 3})
      finalized = entry(ctx, "spec_decided", %{"decision" => "finalized", "version" => 3})

      rejected =
        entry(ctx, "spec_decided", %{
          "decision" => "rejected",
          "version" => 3,
          "reason" => "Add errors"
        })

      text =
        ctx.lead
        |> run(ctx.task, [reviewed, approved, finalized, rejected], %{squad_id: ctx.squad.id})
        |> prompt()

      i = ctx.ident

      assert text =~
               "- #{bob.name} reviewed version 2 of the spec of #{i}: fail, 3 issues (1 P1, 1 P2, 1 P3). " <>
                 "Read them with list_spec_reviews(\"#{i}\")."

      assert text =~
               "- #{alice(ctx)} approved the spec of #{i}: version 3 is final. Continue with the implementation according to it."

      assert text =~ "- #{alice(ctx)} finalized the spec of #{i} at version 3. Continue"

      assert text =~
               "- #{alice(ctx)} sent the spec of #{i} back:\n> Add errors\nRevise it before proposing again."
    end
  end

  describe "leader 提示词的规格流程" do
    defp leader_prompt(ctx, resume? \\ false) do
      run = run(ctx.lead, ctx.task, [entry(ctx, "assign", %{})], %{squad_id: ctx.squad.id})

      if resume? do
        run_fixture(ctx.lead, %{
          task_id: ctx.task.id,
          status: :succeeded,
          session_id: "s-1",
          squad_id: ctx.squad.id,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })
      end

      prompt(run)
    end

    defp section(text) do
      [_, rest] = String.split(text, "\n\n## Specs\n", parts: 2)
      [section | _] = String.split(rest, "\n\n---\n", parts: 2)
      section
    end

    test "an empty spec, approval mode", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
      text = leader_prompt(ctx)
      section = section(text)

      assert section =~ ~s(spec: "draft")
      assert section =~ "finalize_spec"
      assert section =~ "a person must approve"
      assert section =~ "Do not schedule implementation before the spec is final."
      assert byte_size("## Specs\n" <> section) <= 2048
      assert text =~ "Spec: #{ctx.ident} needs a spec"
    end

    test "leader mode, and in a resumed session", ctx do
      {_u, admin} = member_scope_fixture(ctx.workspace, :admin)
      {:ok, _} = Squads.update(admin, "web-team", %{spec_finalize: "leader"})
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 1)

      assert section(leader_prompt(ctx, true)) =~
               "finalize_spec makes it final directly; you are responsible for that decision."
    end

    test "no spec: one sentence", ctx do
      assert section(leader_prompt(ctx)) ==
               "If this task needs a spec first, create one with submit_spec_version or " <>
                 "delegate(…, spec: \"draft\")."
    end

    test "other tasks of the workspace do not matter", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, other.ident, %{title: "x"})
      spec_fixture(ctx.alice_scope, other.ident)
      refute leader_prompt(ctx) =~ "Spec: "
    end
  end
end

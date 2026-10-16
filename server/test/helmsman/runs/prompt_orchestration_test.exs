defmodule Helmsman.Runs.PromptOrchestrationTest do
  # improve-squad-leader-orchestration: the prompt lines of orchestration
  # (decision 15). 2.4: the `epic_stalled` trigger line; 3.3: the trigger
  # lines of a mention or manual run of a squad's leader; 4.3: the leader's
  # identity line, how to lead and the orchestration section.
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Dispatch, Feedback, Runs, Tasks, Tx}
  alias Helmsman.Runs.{Prompt, Run, Spec}
  alias Helmsman.Squads.EpicWatch
  alias Helmsman.Tasks.Task, as: TaskRow
  alias HelmsmanProtocol.RunSpec

  @token "hmr_" <> String.duplicate("a", 52)

  defp spec_prompt(run) do
    {:ok, %RunSpec{prompt: prompt}} =
      Spec.build(Repo.get!(Run, run.id), @token, "https://hm.test")

    prompt
  end

  defp stalled_run(ctx) do
    :woken = EpicWatch.check(ctx.epic.id)
    run = Repo.one!(from(r in Run, where: r.task_id == ^ctx.epic.id and r.status == :queued))
    run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
  end

  describe "epic_stalled (2.4)" do
    setup do
      ctx = orchestration_fixture()
      Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
      ctx
    end

    test "the epic_stalled line lists the idle steps and their reasons", ctx do
      text = ctx |> stalled_run() |> spec_prompt()
      e = ctx.epic.ident

      assert text =~
               "- Helmsman woke you because #{e} has made no progress: nothing is running on it " <>
                 "or its steps, and these steps are idle: #{ctx.s1.ident} (keel/fe: no run), " <>
                 "#{ctx.s2.ident} (keel/review: no run), #{ctx.s3.ident} (unassigned). Start, " <>
                 "assign or order them (see the Orchestration section), or write a question on " <>
                 "#{e} if you need a person. If waiting is right, say why and end the run; " <>
                 "Helmsman will not wake you again until something changes."
    end

    test "over 20 idle steps: 20 listed and the rest counted", ctx do
      for n <- 1..20 do
        {:ok, _} =
          Helmsman.Tasks.create(ctx.alice_scope, ctx.project.key, %{
            title: "more #{n}",
            epic: ctx.epic.ident,
            start: false
          })
      end

      run = stalled_run(ctx)
      [%{"idle" => idle, "idle_count" => 23}] = run.triggers
      assert length(idle) == 20

      assert spec_prompt(run) =~
               ~s[ (3 more; get_task("#{ctx.epic.ident}") lists all). Start, assign]
    end
  end

  defp prompt(ctx) do
    [run] =
      Repo.all(from(r in Run, where: r.task_id == ^ctx.epic.id and r.status == :queued))

    run = run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
    {:ok, %RunSpec{prompt: prompt}} = Spec.build(run, @token, "https://hm.test")
    prompt
  end

  defp why(prompt) do
    [_, rest] = String.split(prompt, "Why you were started:\n", parts: 2)
    rest |> String.split("\nWorking directory:", parts: 2) |> hd()
  end

  describe "a mentioned or started leader (3.3, 4.3)" do
    setup do
      ctx = squads_fixture()
      epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic", title: "Emulator"})
      {:ok, _} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team"})
      Tx.run(fn -> {:ok, Runs.cancel_pending(from(r in Run), :obsolete)} end)

      Map.merge(ctx, %{
        epic: epic,
        alice_name: human_actor(ctx.workspace, ctx.alice).name,
        carol_name: human_actor(ctx.workspace, ctx.carol).name
      })
    end

    test "a mention of the leader as the leader of the squad", ctx do
      {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "@keel/lead go on"})

      assert why(prompt(ctx)) ==
               """
               - #{ctx.alice_name} mentioned you, as the leader of your squad web-team, in #{ctx.epic.ident}##{entry.seq}:
               > @keel/lead go on
               Reply with add_feedback. You were asked to reply, not to take over #{ctx.epic.ident}.\
               """
    end

    test "a manual run as the leader of the squad", ctx do
      {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.epic.ident, "Carry on")

      assert why(prompt(ctx)) ==
               """
               - #{ctx.alice_name} started you as the leader of your squad web-team on #{ctx.epic.ident}.
               Instructions from #{ctx.alice_name}:
               > Carry on\
               """
    end

    test "a refused upgrade says why the run is not as the squad", ctx do
      note =
        "You lead the squad web-team, which owns #{ctx.epic.ident}, but #{ctx.carol_name} may " <>
          "not trigger all of its members (keel/qa), so this run is not as the squad: you cannot " <>
          "delegate or orchestrate. Ask someone who may trigger the squad to mention @web-team."

      {:ok, entry} = Feedback.add(ctx.carol_scope, ctx.epic.ident, %{content: "@keel/lead ?"})

      assert why(prompt(ctx)) ==
               """
               - #{ctx.carol_name} mentioned you in #{ctx.epic.ident}##{entry.seq}:
               > @keel/lead ?
               #{note}
               Reply with add_feedback. You were asked to reply, not to take over #{ctx.epic.ident}.\
               """

      Tx.run(fn -> {:ok, Runs.cancel_pending(from(r in Run), :obsolete)} end)
      {:ok, _} = Dispatch.run_agent(ctx.carol_scope, "keel/lead", ctx.epic.ident, nil)

      assert why(prompt(ctx)) == "- #{ctx.carol_name} started you manually.\n#{note}"
    end

    test "the leader's prompt: how to lead, and the identity line and section with a root",
         ctx do
      # Rule 1 of the root (decision 1): the run's task is assigned to the squad.
      {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.epic.ident, nil)
      prompt = prompt(ctx)
      ident = ctx.epic.ident

      assert prompt =~
               "You may change #{ident}. As the leader of web-team you may also orchestrate the " <>
                 "tasks of #{ident} (this task) listed in the Orchestration section: assign them " <>
                 "to members (update_task with assignee and start), start their assignee " <>
                 "(start_task) and order them (link_tasks / unlink_tasks with depends_on). You " <>
                 "cannot move them to another status or change anything else on them."

      assert prompt =~ "start_task(task_id, instructions) starts a task's assignee"
      assert prompt =~ "(epic_stalled). If waiting is right, say why and end the run."
      refute prompt =~ "start=false"
      assert prompt =~ "\n\n## Orchestration: #{ident} Emulator\n"
      assert prompt =~ "Tasks you can orchestrate (status, assignee, what it waits for):\n"
    end

    test "a member started by orchestration", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key, %{epic: ctx.epic.ident})

      leader_run =
        run_fixture(ctx.lead, %{task_id: ctx.epic.id, squad_id: ctx.squad.id, status: :running})

      run =
        run_fixture(ctx.fe, %{
          task_id: task.id,
          status: :claimed,
          triggers: [
            %{
              "kind" => "assign",
              "by_actor_id" => ctx.lead.id,
              "at" => DateTime.to_iso8601(DateTime.utc_now()),
              "orchestrated" => true,
              "orchestrator_run_id" => leader_run.id,
              "instructions" => "Interfaces are in core/src/bus.rs"
            }
          ]
        })

      {:ok, %RunSpec{prompt: prompt}} = Spec.build(run, @token, "https://hm.test")

      assert prompt =~
               "- keel/lead, leading the squad web-team, started you on #{task.ident}.\n" <>
                 "Instructions from keel/lead:\n> Interfaces are in core/src/bus.rs\n"
    end
  end

  describe "the orchestration section (4.3)" do
    test "snapshot" do
      root = %TaskRow{ident: "ACC-10", title: "NES emulator"}

      rows = [
        row("ACC-12", "PPU and APU", "nes-ppu-apu", :agent, :start, []),
        row("ACC-13", "Desktop shell", nil, nil, :assignment, []),
        row("ACC-14", "Test ROMs", "nes-qa", :agent, :prerequisites, ["ACC-12"]),
        row("ACC-15", "Input mapping", "bob", :human, :assignee, []),
        row("ACC-16", "Release notes", "web-team", :squad, :run, []),
        %{row("ACC-11", "CPU core", "nes-core", :agent, nil, []) | status: :verified}
      ]

      assert Prompt.orchestration_section(root, rows) ==
               """
               ## Orchestration: ACC-10 NES emulator
               Tasks you can orchestrate (status, assignee, what it waits for):
               - ACC-12 [NEW] PPU and APU — nes-ppu-apu (agent); waiting for: start (no run; start_task can start it)
               - ACC-13 [NEW] Desktop shell — unassigned; waiting for: assignment
               - ACC-14 [NEW] Test ROMs — nes-qa (agent); waiting for: prerequisites (ACC-12)
               - ACC-15 [NEW] Input mapping — bob (person); waiting for: assignee
               - ACC-16 [NEW] Release notes — web-team (squad); waiting for: run
               - ACC-11 [VERIFIED] CPU core — nes-core (agent)\
               """

      assert Prompt.orchestration_section(root, []) =~ "\n(none yet)"
    end

    test "at most 50 lines of at most 300 bytes and 16 KB, valid UTF-8" do
      long = String.duplicate("𝄞é", 200)
      root = %TaskRow{ident: "ACC-10", title: long}

      rows =
        for i <- 1..80 do
          blockers = for j <- 1..40, do: "ACC-#{1000 + j}"
          row("ACC-#{100 + i}", long, String.duplicate("名", 20), :agent, :prerequisites, blockers)
        end

      section = Prompt.orchestration_section(root, rows)
      lines = String.split(section, "\n")

      assert String.valid?(section)
      assert byte_size(section) <= 16 * 1024
      assert length(lines) == 2 + 50 + 1
      assert List.last(lines) == ~s[(30 more; get_task("ACC-10") lists all)]
      assert Enum.all?(lines, &(byte_size(&1) <= 300))
      assert hd(lines) =~ ~r/\A## Orchestration: ACC-10 .+…\z/u
    end
  end

  defp row(ident, title, assignee, kind, waiting, blocked) do
    %{
      ident: ident,
      status: :new,
      title: title,
      assignee: assignee,
      assignee_kind: kind,
      waiting_for: waiting,
      blocked_by: blocked
    }
  end

  describe "a callback run's orchestration section (4.3)" do
    setup do
      ctx = orchestration_fixture()
      Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
      ctx
    end

    # Rule 2 of the root (decision 1): the run's task is a step of an epic
    # the squad owns; the section lists the epic's steps, the step itself
    # among them (this run is on it), with what each waits for.
    test "the leader woken on a step orchestrates its epic, resumed too", ctx do
      {_scope, run} = leader_run(ctx, ctx.lead, ctx.s1)
      e = ctx.epic.ident
      [s1, s2, s3] = Enum.map([ctx.s1, ctx.s2, ctx.s3], & &1.ident)

      section = """
      ## Orchestration: #{e} Emulator
      Tasks you can orchestrate (status, assignee, what it waits for):
      - #{s1} [NEW] Core — keel/fe (agent); waiting for: run
      - #{s2} [NEW] PPU — keel/review (agent); waiting for: start (no run; start_task can start it)
      - #{s3} [NEW] Desktop — unassigned; waiting for: assignment\
      """

      prompt = spec_prompt(run)
      assert prompt =~ "\n\n" <> section

      assert prompt =~
               "As the leader of web-team you may also orchestrate the tasks of #{e} listed"

      refute prompt =~ "(this task)"

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [status: :succeeded, session_id: "s-1", started_at: DateTime.utc_now()]
      )

      {_scope, resumed} = leader_run(ctx, ctx.lead, ctx.s1)
      prompt = spec_prompt(resumed)
      assert Spec.resume_session_id(resumed) == "s-1"
      refute prompt =~ "Squad instructions"
      assert prompt =~ ~r/\A## Squad web-team\n/
      assert prompt =~ "\n\n" <> section
    end

    test "a squad run without a root has no orchestration section", ctx do
      loose = task_fixture(ctx.alice_scope, ctx.project.key)
      {_scope, run} = leader_run(ctx, ctx.lead, loose)
      prompt = spec_prompt(run)
      assert prompt =~ "## Squad web-team"
      refute prompt =~ "## Orchestration"
    end
  end
end

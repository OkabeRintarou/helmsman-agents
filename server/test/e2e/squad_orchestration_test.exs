defmodule Helmsman.E2E.SquadOrchestrationTest do
  # improve-squad-leader-orchestration 5.1: the ACC-10 story with the real
  # daemon and fake CLIs that call /mcp over HTTP with their run tokens
  # (`test/support/fake_cli/spec-workflow-mcp.py`, one plan of turns per
  # agent). The epic is ACC-1 here (ACC-10 in the story), its steps ACC-2
  # (ACC-11, nes-core), ACC-3 (ACC-12, nes-ppu-apu), ACC-4 (ACC-13,
  # nes-desktop) and ACC-5 (ACC-14, nes-qa); ACC-7 is a step of another
  # epic (ACC-21). Run with
  # `mix test --only e2e test/e2e/squad_orchestration_test.exs`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 300_000
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Actors, CommittedData, DaemonE2E, Feedback, Repo, Tasks}
  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.EpicWatch
  alias Helmsman.Tasks.Task

  @cli_script Path.expand("../support/fake_cli/spec-workflow-mcp.py", __DIR__)

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    previous = Application.get_env(:helmsman, EpicWatch)

    on_exit(fn ->
      Application.put_env(:helmsman, EpicWatch, previous || [])
      Sandbox.mode(Repo, :manual)
    end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-orch-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    {alice, workspace, scope, project, daemon, token} =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "orch-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(alice, %{slug: "orch-e2e-#{tag}"})
        scope = workspace_scope_fixture(alice, workspace)
        {:ok, actor} = Actors.rename_own(scope, "alice")
        scope = %{scope | actor: actor}
        project = project_fixture(scope, %{key: "ACC"})
        {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
        {alice, workspace, scope, project, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([alice.id]) end)

    %{
      home: home,
      scope: scope,
      project: project,
      workspace: workspace,
      daemon: daemon,
      token: token
    }
  end

  defp start(ctx) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    # A wake-up can arrive before the daemon releases the previous run's
    # capacity; its heartbeat retries the claim, shortened here.
    port = DaemonE2E.start_e2e_daemon(ctx.home, %{heartbeat_interval_ms: 100})

    runtime =
      DaemonE2E.wait_until(port, "runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime}
  end

  defp call(tool, args, error \\ false), do: %{tool: tool, args: args, error: error}
  defp turn(name, calls), do: %{name: name, calls: calls}

  defp install_cli(ctx, runtime, name, turns) do
    plan = Path.join(ctx.home, "#{name}.json")
    scenario = Path.join(ctx.home, "#{name}.scenario")
    File.write!(plan, Jason.encode!(turns))
    command = Enum.map_join(["python3", @cli_script, plan, ctx.home], " ", &shell_quote/1)
    File.write!(scenario, "sh #{command}\nexit 0\n")

    managed_agent_fixture(ctx.scope, %{
      name: name,
      runtime_id: runtime.id,
      access: "workspace",
      custom_args: [scenario]
    })
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp marker(ctx, name, suffix), do: Path.join(ctx.home, "#{name}.#{suffix}")

  defp receipt(port, ctx, name, suffix) do
    DaemonE2E.wait_until(port, "#{name}.#{suffix}", fn ->
      error = marker(ctx, name, "error")

      refute File.exists?(error),
             "fake CLI failed: #{if File.exists?(error), do: File.read!(error)}"

      case File.read(marker(ctx, name, suffix)) do
        {:ok, json} -> Jason.decode!(json)
        _ -> nil
      end
    end)
  end

  defp ready(port, ctx, name) do
    receipt = receipt(port, ctx, name, "ready")
    run = Repo.get!(Run, receipt["run_id"])
    assert run.status == :running
    {run, receipt["prompt"]}
  end

  defp execute(port, ctx, name) do
    File.write!(marker(ctx, name, "release"), "")
    receipt(port, ctx, name, "done")["results"]
  end

  defp finish(port, ctx, name, run) do
    File.write!(marker(ctx, name, "finish"), "")

    ended =
      DaemonE2E.wait_until(port, "#{name} ended", fn ->
        current = Repo.get!(Run, run.id)
        current.status in Run.ended_statuses() && current
      end)

    assert ended.status == :succeeded
    assert %{failure: 0} = Oban.drain_queue(queue: :runs)
  end

  # Runs the jobs the daemon's reports leave (run side effects, then what
  # they insert, scheduled stall checks excepted) until `fun` holds.
  defp settle(port, label, fun) do
    DaemonE2E.wait_until(port, label, fn ->
      assert %{failure: 0} = Oban.drain_queue(queue: :runs)
      assert %{failure: 0} = Oban.drain_queue(queue: :default)
      fun.()
    end)
  end

  # Runs the waiting jobs of the default queue, the stall checks included
  # (`grace_seconds: 0`, scheduled ones too).
  defp drain_checks do
    assert %{failure: 0} = Oban.drain_queue(queue: :default, with_scheduled: true)
  end

  defp task!(ident), do: Repo.get_by!(Task, ident: ident)

  defp notes(ident) do
    Repo.all(
      from(f in Entry,
        join: a in Actor,
        on: a.id == f.author_id,
        join: t in Task,
        on: t.id == f.task_id,
        where: t.ident == ^ident and a.kind == :system,
        order_by: f.seq,
        select: f.content
      )
    )
  end

  defp runs_on(ident) do
    Repo.all(
      from(r in Run,
        join: t in Task,
        on: t.id == r.task_id,
        where: t.ident == ^ident,
        order_by: r.id
      )
    )
  end

  defp step(title, assignee, extra \\ %{}) do
    call(
      "create_task",
      Map.merge(
        %{project_key: "ACC", title: title, epic: "ACC-1", assignee: assignee},
        extra
      )
    )
  end

  test "ACC-10: subtasks with depends_on, callback orchestration, @leader, the stall watchdog",
       ctx do
    Application.put_env(:helmsman, EpicWatch, grace_seconds: 0)
    {port, runtime} = start(ctx)
    lead = "nes-lead"

    install_cli(ctx, runtime, lead, [
      # On the epic: every step at once, ordered with depends_on.
      turn("lead-1", [
        step("CPU core", "nes-core"),
        step("PPU and APU", "nes-ppu-apu", %{start: false}),
        step("Desktop shell", "nes-desktop", %{start: false, depends_on: ["ACC-2"]}),
        step("Test ROMs", "nes-qa", %{start: false})
      ]),
      # Woken by ACC-2 done (its task is ACC-2): accept it, then orchestrate
      # the epic's other steps.
      turn("lead-2", [
        call("transition_task", %{task_id: "ACC-2", to: "verified", comment: "CPU core works."}),
        call("link_tasks", %{from: "ACC-5", to: "ACC-3", type: "depends_on"}),
        call("start_task", %{task_id: "ACC-3", instructions: "Bus interfaces are in core/"}),
        call("start_task", %{task_id: "ACC-5"})
      ]),
      # Variant A: woken by ACC-3 done, it only accepts.
      turn("lead-3", [
        call("transition_task", %{task_id: "ACC-3", to: "verified", comment: "PPU works."})
      ]),
      # Woken by the watchdog on ACC-1: waiting is right, it does nothing.
      turn("lead-4", []),
      # Variant B: @nes-lead on ACC-1, as the squad.
      turn("lead-5", [
        call("start_task", %{task_id: "ACC-4"}),
        call("update_task", %{task_id: "ACC-3", title: "PPU only"}, true),
        call("update_task", %{task_id: "ACC-7", assignee: "nes-qa"}, true)
      ])
    ])

    install_cli(ctx, runtime, "nes-core", [
      turn("core-1", [
        call("transition_task", %{task_id: "ACC-2", to: "done", comment: "CPU core done."})
      ])
    ])

    install_cli(ctx, runtime, "nes-ppu-apu", [
      turn("ppu-1", [call("transition_task", %{task_id: "ACC-3", to: "done", comment: "Done."})])
    ])

    install_cli(ctx, runtime, "nes-desktop", [turn("desktop-1", [])])
    install_cli(ctx, runtime, "nes-qa", [turn("qa-1", [])])

    squad =
      squad_fixture(ctx.scope, %{
        name: "nes-emulator",
        leader: lead,
        members: [
          %{name: "nes-core", role_note: "CPU"},
          %{name: "nes-ppu-apu", role_note: "PPU and APU"},
          %{name: "nes-desktop", role_note: "Desktop shell"},
          %{name: "nes-qa", role_note: "Test ROMs"}
        ]
      })

    epic = task_fixture(ctx.scope, ctx.project.key, %{kind: :epic, title: "NES emulator"})
    assert epic.ident == "ACC-1"
    {:ok, _} = Tasks.update(ctx.scope, epic.ident, %{assignee: squad.name})

    # 1. The leader creates the steps; only ACC-2 starts.
    {lead1, _prompt} = ready(port, ctx, "lead-1")
    assert lead1.squad_id == squad.id
    assert "orchestrate" in lead1.capabilities
    results = execute(port, ctx, "lead-1")
    assert Enum.map(results, & &1["value"]["id"]) == ~w(ACC-2 ACC-3 ACC-4 ACC-5)
    finish(port, ctx, "lead-1", lead1)

    other = task_fixture(ctx.scope, ctx.project.key, %{kind: :epic, title: "Other"})
    outside = task_fixture(ctx.scope, ctx.project.key, %{epic: other.ident, title: "Elsewhere"})
    assert {other.ident, outside.ident} == {"ACC-6", "ACC-7"}

    for ident <- ~w(ACC-3 ACC-4 ACC-5), do: assert(runs_on(ident) == [])

    # 2. nes-core finishes ACC-2.
    {core1, _} = ready(port, ctx, "core-1")
    assert task!("ACC-2").id == core1.task_id
    execute(port, ctx, "core-1")
    finish(port, ctx, "core-1", core1)

    # 3. The leader, woken on ACC-2, sees and orchestrates the epic.
    {lead2, prompt} = ready(port, ctx, "lead-2")
    assert lead2.task_id == task!("ACC-2").id
    assert lead2.squad_id == squad.id
    assert "orchestrate" in lead2.capabilities
    assert prompt =~ "\n## Orchestration: ACC-1 NES emulator\n"

    for {ident, title, member} <- [
          {"ACC-3", "PPU and APU", "nes-ppu-apu"},
          {"ACC-4", "Desktop shell", "nes-desktop"},
          {"ACC-5", "Test ROMs", "nes-qa"}
        ] do
      assert prompt =~
               "- #{ident} [NEW] #{title} — #{member} (agent); waiting for: start (no run; " <>
                 "start_task can start it)"
    end

    assert [
             %{"value" => %{"status" => "VERIFIED"}},
             %{"value" => _link},
             %{"value" => %{"result" => "queued", "run" => %{"agent" => "nes-ppu-apu"}}},
             %{"value" => %{"result" => "deferred", "blocked_by" => ["ACC-3"]}}
           ] = execute(port, ctx, "lead-2")

    prefix =
      "Orchestration by #{lead} (squad nes-emulator, run #{lead2.id} on ACC-2, root ACC-1): "

    assert [link_note, start_note] = notes("ACC-5")
    assert link_note == prefix <> "ACC-5 now depends on ACC-3."
    assert start_note =~ prefix <> "started nes-qa on ACC-5."
    assert [ppu_note] = notes("ACC-3")
    assert ppu_note =~ prefix <> "started nes-ppu-apu on ACC-3."
    assert [%Run{status: :deferred}] = runs_on("ACC-5")
    finish(port, ctx, "lead-2", lead2)

    # 4. nes-ppu-apu finishes ACC-3: ACC-5's run is released; the leader,
    # woken on ACC-3, only accepts it (variant A).
    {ppu1, prompt} = ready(port, ctx, "ppu-1")
    assert [%{"kind" => "assign", "orchestrated" => true}] = ppu1.triggers
    assert prompt =~ "- #{lead}, leading the squad nes-emulator, started you on ACC-3."
    assert prompt =~ "> Bus interfaces are in core/"
    execute(port, ctx, "ppu-1")
    finish(port, ctx, "ppu-1", ppu1)

    # The leader's callback run on ACC-3 keeps it unsatisfied (a running
    # run, designs/07 §3) until it ends; then the run's side effects
    # release ACC-5 after the commit (ReleaseDependents).
    {lead3, _} = ready(port, ctx, "lead-3")
    assert lead3.task_id == task!("ACC-3").id
    assert lead3.squad_id == squad.id
    assert [%Run{status: :deferred}] = runs_on("ACC-5")
    assert [%{"value" => %{"status" => "VERIFIED"}}] = execute(port, ctx, "lead-3")
    finish(port, ctx, "lead-3", lead3)

    settle(port, "ACC-5 released", fn ->
      match?([%Run{status: status}] when status != :deferred, runs_on("ACC-5"))
    end)

    {qa1, _} = ready(port, ctx, "qa-1")
    assert qa1.task_id == task!("ACC-5").id

    assert [%{"kind" => "assign", "orchestrated" => true}, %{"kind" => "unblocked"}] =
             qa1.triggers

    execute(port, ctx, "qa-1")
    finish(port, ctx, "qa-1", qa1)

    # 5. Nothing runs and ACC-4 is idle: the watchdog wakes the leader on
    # the epic, as the squad. It ends without doing anything; the next
    # check does not wake it again.
    settle(port, "the runs settled", fn -> true end)
    drain_checks()
    {lead4, prompt} = ready(port, ctx, "lead-4")
    assert lead4.task_id == epic.id
    assert lead4.squad_id == squad.id
    assert [%{"kind" => "epic_stalled"}] = lead4.triggers
    assert prompt =~ "Helmsman woke you because ACC-1 has made no progress"
    assert prompt =~ "ACC-4 (nes-desktop: no run)"
    execute(port, ctx, "lead-4")
    finish(port, ctx, "lead-4", lead4)
    drain_checks()
    assert EpicWatch.check(epic.id) in [:same_signature, :too_soon]
    assert Enum.filter(runs_on("ACC-1"), &(&1.id > lead4.id)) == []

    # 6. Variant B: alice writes @nes-lead on ACC-1; the reply runs as the
    # squad and orchestrates; writes beyond orchestration are refused.
    {:ok, _} = Feedback.add(ctx.scope, epic.ident, %{content: "@nes-lead 继续"})
    {lead5, _} = ready(port, ctx, "lead-5")
    assert lead5.task_id == epic.id
    assert lead5.squad_id == squad.id
    assert [%{"kind" => "mention", "as_leader" => true}] = lead5.triggers
    assert "delegate" in lead5.capabilities
    assert "orchestrate" in lead5.capabilities

    assert [
             %{"value" => %{"result" => "queued", "run" => %{"agent" => "nes-desktop"}}},
             %{"error" => true, "value" => fields},
             %{"error" => true, "value" => outside_text}
           ] = execute(port, ctx, "lead-5")

    assert fields ==
             "When orchestrating ACC-3 you may only change assignee and start. Put guidance " <>
               "in start_task instructions instead."

    assert outside_text ==
             "ACC-7 is not part of ACC-1, which you lead in this run. You may only " <>
               "orchestrate its steps and the tasks your squad created for it."

    assert task!("ACC-3").title == "PPU and APU"
    assert task!("ACC-7").assignee_id == nil
    assert [desktop_note] = notes("ACC-4")
    assert desktop_note =~ "run #{lead5.id} on ACC-1, root ACC-1): started nes-desktop on ACC-4."
    finish(port, ctx, "lead-5", lead5)

    {desktop1, _} = ready(port, ctx, "desktop-1")
    execute(port, ctx, "desktop-1")
    finish(port, ctx, "desktop-1", desktop1)

    assert Enum.map(~w(ACC-2 ACC-3 ACC-4 ACC-5), &task!(&1).status) ==
             [:verified, :verified, :in_progress, :in_progress]

    DaemonE2E.stop_daemon(port)
  end
end

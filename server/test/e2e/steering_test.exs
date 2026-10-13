defmodule Helmsman.E2E.SteeringTest do
  # add-run-steering 3.1: this server and the daemon of `daemon/` with its
  # fake CLI in steering modes. Run with `mix test --only e2e`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 180_000

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, Feedback, Repo}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Run, RunEvent, RunSteer, Steering}

  @content "Use the \"v2\" API\nand keep the tests"

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-steer-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    {owner, workspace, scope, project, daemon, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "steer-e2e-#{tag}@test.invalid"})

        workspace =
          workspace_fixture(owner, %{slug: "steer-e2e-#{tag}", name: "Steer e2e #{tag}"})

        scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(scope)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})
        {owner, workspace, scope, project, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{
      tag: tag,
      home: home,
      owner: owner,
      workspace: workspace,
      scope: scope,
      project: project,
      daemon: daemon,
      token: token
    }
  end

  defp start(ctx) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    port = DaemonE2E.start_daemon(ctx.home)

    runtime =
      DaemonE2E.wait_until(port, "the runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime}
  end

  # The agent's fake CLI: the scenario, then the steering mode.
  defp agent(ctx, runtime, lines, mode) do
    path = Path.join(ctx.home, "scenario")
    File.write!(path, Enum.join(lines, "\n") <> "\n")

    managed_agent_fixture(ctx.scope, %{
      name: "keel/dev",
      runtime_id: runtime.id,
      custom_args: [path | List.wrap(mode)]
    })
  end

  defp assign(ctx) do
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)
    {task, run}
  end

  defp steer(ctx, task, run) do
    {:ok, entry} =
      Feedback.add(ctx.scope, task.ident, %{content: @content, steer_run_id: run.id})

    assert [%{trigger: "steer", result: "queued", run_id: fallback_id}] =
             Feedback.view(entry).dispatch

    {entry, Repo.get!(Run, fallback_id)}
  end

  defp wait_status(port, run, statuses, label) do
    DaemonE2E.wait_until(
      port,
      fn -> "#{label} (#{inspect(Repo.get!(Run, run.id), limit: :infinity)})" end,
      fn ->
        run = Repo.get!(Run, run.id)
        run.status in statuses && run
      end
    )
  end

  defp wait_acked(port, run, entry) do
    DaemonE2E.wait_until(port, "the steering receipt", fn ->
      match?(
        %RunSteer{acked_at: %DateTime{}},
        Repo.get_by(RunSteer, run_id: run.id, feedback_id: entry.id)
      )
    end)
  end

  defp events(run, type) do
    Repo.all(
      from(e in RunEvent,
        where: e.run_id == ^run.id and e.type == ^type,
        order_by: e.seq,
        select: e.data
      )
    )
  end

  defp executed(task),
    do:
      Repo.aggregate(
        from(r in Run, where: r.task_id == ^task.id and not is_nil(r.started_at)),
        :count
      )

  defp assert_settled(port, task, run, fallback) do
    run = wait_status(port, run, [:succeeded, :failed, :cancelled], "the steered run's end")
    assert %Run{status: :succeeded, summary: summary} = run
    assert summary =~ "> Use the \"v2\" API"
    assert summary =~ "> and keep the tests"

    # The steer_settle side effect, or the claim's settling, whichever first.
    Oban.drain_queue(queue: :runs)

    fallback =
      wait_status(port, fallback, [:cancelled, :succeeded, :failed], "the fallback settled")

    assert %Run{status: :cancelled, failure_reason: :obsolete, started_at: nil} = fallback
    assert fallback.error =~ "steering delivered to run #{run.id}"
    assert executed(task) == 1
  end

  test "① steered, acknowledged, succeeded: the fallback is cancelled, one run executed",
       ctx do
    {port, runtime} = start(ctx)
    agent(ctx, runtime, ["await_steer", "result_steered", "exit 0"], "pending")
    {task, run} = assign(ctx)
    wait_status(port, run, [:running], "the run running")

    {entry, fallback} = steer(ctx, task, run)
    wait_acked(port, run, entry)
    assert_settled(port, task, run, fallback)
  end

  test "② the CLI cannot be steered: the fallback runs after it with the steer line",
       ctx do
    {port, runtime} = start(ctx)
    result = ~s(json {"type":"result","data":{"text":"done","success":true}})
    agent(ctx, runtime, ["echo_stdin", "sleep 3", result, "exit 0"], nil)
    {task, run} = assign(ctx)
    wait_status(port, run, [:running], "the run running")

    {entry, fallback} = steer(ctx, task, run)
    run = wait_status(port, run, [:succeeded, :failed, :cancelled], "the steered run's end")
    assert run.status == :succeeded

    assert Enum.any?(
             events(run, "status"),
             &(&1["message"] =~ "the message is queued for a run after this one")
           )

    assert %RunSteer{acked_at: nil} =
             Repo.get_by!(RunSteer, run_id: run.id, feedback_id: entry.id)

    Oban.drain_queue(queue: :runs)

    fallback = wait_status(port, fallback, [:succeeded, :failed, :cancelled], "the fallback run")
    assert fallback.status == :succeeded
    prompt = fallback |> events("text") |> Enum.map_join("\n", & &1["text"])
    id = Feedback.view(entry).id

    assert prompt =~
             "wrote #{id} while your run #{run.id} was in progress; that run did not " <>
               "finish with it. Act on it now unless you already have:"

    assert prompt =~ "> Use the \"v2\" API"
    assert executed(task) == 2
  end

  test "③ the push is lost: after the daemon joins again it is pushed again and acknowledged",
       ctx do
    {port, runtime} = start(ctx)
    agent(ctx, runtime, ["await_steer", "result_steered", "exit 0"], "delivered")
    {task, run} = assign(ctx)
    wait_status(port, run, [:running], "the run running")

    # The daemon's channel is suspended, so the push after the commit stays
    # in its mailbox, then it is killed with it: the first push is lost for
    # sure, and only the next join can deliver the message (code-review-6).
    topic = "daemon:#{ctx.daemon.id}"
    [{channel, _}] = Registry.lookup(Helmsman.PubSub, topic)
    :ok = :sys.suspend(channel)
    {entry, fallback} = steer(ctx, task, run)

    assert {:messages, messages} = Process.info(channel, :messages)
    assert {:steer_run, run.id, entry.id, Steering.text(entry)} in messages

    assert %RunSteer{acked_at: nil} =
             Repo.get_by!(RunSteer, run_id: run.id, feedback_id: entry.id)

    ref = Process.monitor(channel)
    Process.exit(channel, :kill)
    assert_receive {:DOWN, ^ref, :process, ^channel, :killed}, 5_000

    DaemonE2E.wait_until(port, "the daemon joined again", fn ->
      match?([{pid, _}] when pid != channel, Registry.lookup(Helmsman.PubSub, topic))
    end)

    wait_acked(port, run, entry)
    assert_settled(port, task, run, fallback)
  end
end

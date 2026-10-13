defmodule Helmsman.E2E.DaemonRunTest do
  # add-run-lifecycle 7.1 (decision 22): this server and the daemon of
  # `daemon/` with its fake CLI run a whole run. Run with
  # `mix test --only e2e`.
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
  alias Helmsman.{CommittedData, DaemonE2E, Repo, Runs}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Run, RunEvent}
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-run-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    {owner, workspace, scope, project, daemon, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "run-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "run-e2e-#{tag}", name: "Run e2e #{tag}"})
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

  defp start(ctx, env \\ []) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    port = DaemonE2E.start_daemon(ctx.home, env)

    runtime =
      DaemonE2E.wait_until(port, "the runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime}
  end

  defp scenario(ctx, name, lines) do
    path = Path.join(ctx.home, name)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp agent(ctx, runtime, scenario) do
    managed_agent_fixture(ctx.scope, %{
      name: "keel/dev",
      runtime_id: runtime.id,
      custom_args: [scenario]
    })
  end

  defp assign(ctx) do
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)
    {task, run}
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

  defp events_text(run) do
    Repo.all(
      from(e in RunEvent,
        where: e.run_id == ^run.id and e.type == "text",
        order_by: e.seq,
        select: e.data["text"]
      )
    )
  end

  defp result(text), do: ~s(json {"type":"result","data":{"text":"#{text}","success":true}})

  defp auto_claims(task),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^task.id and e.auto), :count)

  test "assigned → claimed → started on the task → events → succeeded → fallback comment (scenario)",
       ctx do
    {port, runtime} = start(ctx)

    path =
      scenario(ctx, "work", [
        "out working-#{ctx.tag}",
        "sleep 2",
        result("Implemented X."),
        "exit 0"
      ])

    agent(ctx, runtime, path)
    {task, run} = assign(ctx)

    wait_status(port, run, [:running], "the run running")
    Oban.drain_queue(queue: :runs)
    assert Repo.get!(Task, task.id).status == :in_progress
    assert auto_claims(task) == 1

    run = wait_status(port, run, [:succeeded, :failed, :cancelled], "the run's end")
    assert %Run{status: :succeeded, summary: "Implemented X."} = run
    assert "working-#{ctx.tag}" in events_text(run)

    Oban.drain_queue(queue: :runs)

    assert [%Entry{content: "Implemented X.", fallback: true, author_id: author_id}] =
             Repo.all(from(f in Entry, where: f.task_id == ^task.id))

    assert author_id == run.agent_id
  end

  test "stopping a running run: cancelled, the CLI and its child are gone", ctx do
    pid_file = Path.join(ctx.home, "child.pid")
    {port, runtime} = start(ctx, [{~c"FAKE_CLI_CHILD_PID_FILE", String.to_charlist(pid_file)}])
    path = scenario(ctx, "long", ["spawn_child", "out started", "sleep 600"])
    agent(ctx, runtime, path)
    {_task, run} = assign(ctx)

    wait_status(port, run, [:running], "the run running")

    child =
      DaemonE2E.wait_until(port, "the child's pid", fn ->
        case File.read(pid_file) do
          {:ok, text} when text != "" -> String.trim(text)
          _ -> nil
        end
      end)

    assert {:ok, %{status: "cancelling"}} = Runs.cancel(ctx.scope, run.id)

    assert %Run{status: :cancelled} =
             wait_status(port, run, [:succeeded, :failed, :cancelled], "the run's end")

    DaemonE2E.wait_until(port, "the child process gone", fn ->
      {_out, status} = System.cmd("kill", ["-0", child], stderr_to_stdout: true)
      status != 0
    end)
  end

  test "the starting reply is lost: the daemon resends it, the CLI runs once", ctx do
    previous = Application.fetch_env(:helmsman, :daemon_channel_drop_replies)
    Application.put_env(:helmsman, :daemon_channel_drop_replies, ["starting"])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:helmsman, :daemon_channel_drop_replies, value)
        :error -> Application.delete_env(:helmsman, :daemon_channel_drop_replies)
      end
    end)

    {port, runtime} = start(ctx)
    marker = "once-#{ctx.tag}"
    path = scenario(ctx, "once", ["out #{marker}", result("Done."), "exit 0"])
    agent(ctx, runtime, path)
    {task, run} = assign(ctx)

    run = wait_status(port, run, [:succeeded, :failed, :cancelled], "the run's end")
    assert run.status == :succeeded
    assert Enum.count(events_text(run), &(&1 == marker)) == 1

    Oban.drain_queue(queue: :runs)
    assert auto_claims(task) == 1
  end
end

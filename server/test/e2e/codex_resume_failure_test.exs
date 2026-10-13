defmodule Helmsman.E2E.CodexResumeFailureTest do
  # #52 task 3.3: the real daemon and Codex adapter exercise claim/report over
  # the local server; the fake CLI records only session and prompt fields.
  use ExUnit.Case, async: false
  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 180_000

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, Repo, Runs, Tx}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Origin, Run}

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-codex-resume-#{tag}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    ctx =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "codex-resume-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "codex-resume-#{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(scope)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})

        %{
          owner: owner,
          workspace: workspace,
          scope: scope,
          project: project,
          daemon: daemon,
          token: token
        }
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.owner.id]) end)
    Map.put(ctx, :home, home)
  end

  for mode <- ["missing", "success"] do
    test "resume #{mode}: only confirmed sessions influence the next description", ctx do
      mode = unquote(mode)
      url = DaemonE2E.start_endpoint()
      DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
      codex_home = Path.join(ctx.home, "user-codex")
      File.mkdir_p!(codex_home)
      File.write!(Path.join(codex_home, "config.toml"), ~s(model_provider="ollama"))
      cli = install_cli(ctx.home)
      transcript = Path.join(ctx.home, "codex-requests.jsonl")

      port =
        DaemonE2E.start_e2e_daemon(ctx.home, %{}, [
          {~c"HOME", String.to_charlist(ctx.home)},
          {~c"CODEX_HOME", String.to_charlist(codex_home)},
          {~c"HELMSMAN_E2E_CODEX_CLI", String.to_charlist(cli)},
          {~c"CODEX_RESUME_MODE", String.to_charlist(mode)},
          {~c"CODEX_RESUME_TRANSCRIPT", String.to_charlist(transcript)}
        ])

      runtime =
        DaemonE2E.wait_until(port, "Codex online", fn ->
          case Repo.get_by(Runtime,
                 daemon_id: ctx.daemon.id,
                 workspace_id: ctx.workspace.id,
                 provider: "codex"
               ) do
            %Runtime{status: "online"} = runtime -> runtime
            _ -> nil
          end
        end)

      {agent, task, first} =
        CommittedData.unboxed(fn ->
          managed_agent_fixture(ctx.scope, %{
            name: "keel/codex",
            provider: "codex",
            runtime_id: runtime.id
          })

          task = task_fixture(ctx.scope, ctx.project.key, %{assignee: "keel/codex"})
          [first] = runs_of(task.id)
          {agent_actor(ctx.workspace, "keel/codex"), task, first}
        end)

      first = ended(port, first)
      assert first.status == :succeeded
      assert first.session_id == "s-1"

      assert [%{"method" => "thread/start"}, %{"method" => "turn/start"}] =
               requests(transcript)

      second = queue(ctx.scope, agent, task)
      second = ended(port, second)
      assert second.started_at

      assert Enum.at(requests(transcript), 2) == %{
               "method" => "thread/resume",
               "threadId" => "s-1"
             }

      if mode == "missing" do
        assert second.status == :failed
        assert second.failure_reason == :cli_error
        assert second.session_id == nil
      else
        assert second.status == :succeeded
        assert second.session_id == "s-1"
      end

      third = queue(ctx.scope, agent, task)
      third = ended(port, third)
      assert third.status == :succeeded
      assert third.session_id == "s-1"

      [thread, turn] = requests(transcript) |> Enum.take(-2)
      prompt = turn["prompt"]

      if mode == "missing" do
        assert thread == %{"method" => "thread/start", "threadId" => nil}
        assert prompt =~ "You are the agent"
        assert prompt =~ "You may only change #{task.ident}."
        assert prompt =~ "helmsman://workflow"
      else
        assert thread == %{"method" => "thread/resume", "threadId" => "s-1"}
        assert String.starts_with?(prompt, "Why you were started:")
        refute prompt =~ "You are the agent"
      end

      assert prompt =~ "get_task(\"#{task.ident}\")"
      assert turn["method"] == "turn/start"
    end
  end

  defp queue(scope, agent, task) do
    CommittedData.unboxed(fn ->
      assert {:ok, %{result: :queued, run_id: id}} =
               Tx.run(fn ->
                 Runs.enqueue(
                   Origin.from_scope(scope),
                   %{agent: agent, profile: profile(agent), task: task},
                   %{kind: :manual, instructions: nil}
                 )
               end)

      Repo.get!(Run, id)
    end)
  end

  defp ended(port, run) do
    DaemonE2E.wait_until(port, "run completed", fn ->
      current = Repo.get!(Run, run.id)
      current.status in Run.ended_statuses() && current
    end)
  end

  defp install_cli(home) do
    path = Path.join(home, "fake-codex")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, sys
    if "--version" in sys.argv:
        print("codex-cli 0.162.1")
        sys.exit(0)
    def reply(frame):
        print(json.dumps(frame), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method in ("thread/start", "thread/resume", "turn/start"):
            params = request.get("params", {})
            record = {"method": method, "threadId": params.get("threadId")}
            if method == "turn/start":
                record["prompt"] = params["input"][0]["text"]
            with open(os.environ["CODEX_RESUME_TRANSCRIPT"], "a") as output:
                output.write(json.dumps(record) + "\\n")
        if method == "initialize":
            reply({"id": request["id"], "result": {}})
        elif method == "thread/resume" and os.environ["CODEX_RESUME_MODE"] == "missing":
            reply({"id": request["id"], "error": {"code": -32600, "message": "no rollout found for thread id s-1"}})
        elif method in ("thread/start", "thread/resume"):
            reply({"id": request["id"], "result": {"thread": {"id": "s-1"}, "modelProvider": "ollama"}})
        elif method == "turn/start":
            reply({"id": request["id"], "result": {"turn": {"id": "t-1"}}})
            reply({"method": "item/completed", "params": {"threadId": "s-1", "turnId": "t-1", "item": {"id": "m-1", "type": "agentMessage", "text": "OK", "phase": "final_answer"}}})
            reply({"method": "turn/completed", "params": {"threadId": "s-1", "turn": {"id": "t-1", "status": "completed", "error": None}}})
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp requests(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end

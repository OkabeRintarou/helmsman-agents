defmodule HelmsmanDaemon.Case do
  @moduledoc "Isolated home, execution supervisors and polling assertions."
  use ExUnit.CaseTemplate
  alias HelmsmanDaemon.{Config, Detector, Paths, Runs, StateStore, TestReporter}

  using do
    quote do
      alias HelmsmanDaemon.{Credentials, Paths, Runs, TestReporter}
      alias HelmsmanProtocol.Reply
      alias HelmsmanProtocol.Report
      import HelmsmanDaemon.Case
    end
  end

  setup context do
    keys = ["HELMSMAN_HOME", "HOME", "CODEX_HOME"]
    previous = Map.take(System.get_env(), keys)
    user_home = Path.join(context.tmp_dir, "user-home")
    codex_home = Path.join(context.tmp_dir, "codex")
    File.mkdir_p!(user_home)
    File.mkdir_p!(codex_home)

    System.put_env(%{
      "HELMSMAN_HOME" => context.tmp_dir,
      "HOME" => user_home,
      "CODEX_HOME" => codex_home
    })

    Paths.ensure!()

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
      System.put_env(previous)
    end)

    :ok
  end

  def start_execution do
    ExUnit.Callbacks.start_supervised!({Config, []})
    ExUnit.Callbacks.start_supervised!({StateStore, []})
    ExUnit.Callbacks.start_supervised!({Detector, []})

    ExUnit.Callbacks.start_supervised!(
      {Registry, keys: :unique, name: HelmsmanDaemon.RunRegistry}
    )

    ExUnit.Callbacks.start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: HelmsmanDaemon.RunSupervisor}
    )

    ExUnit.Callbacks.start_supervised!({TestReporter, owner: self()})
    ExUnit.Callbacks.start_supervised!({Runs, reporter: TestReporter})
  end

  def credentials do
    %HelmsmanDaemon.Credentials{
      server_url: "http://localhost:49999",
      daemon_id: 1,
      token: "hmd_private_daemon_token",
      issued_at: DateTime.utc_now(),
      workspaces: [%{"id" => 1, "slug" => "bos", "name" => "Bosun"}]
    }
  end

  def spec(id, scenario \\ "success") do
    %HelmsmanProtocol.RunSpec{
      run_id: id,
      workspace: %HelmsmanProtocol.RunSpec.Workspace{id: 1, slug: "bos"},
      task: %HelmsmanProtocol.RunSpec.Task{ident: "BOS-1", title: "Task"},
      agent: %HelmsmanProtocol.RunSpec.Agent{
        name: "Fake",
        provider: :claude,
        model: nil,
        effort: nil,
        custom_args: [scenario],
        env: %{},
        extra_mcp_servers: %{}
      },
      prompt: "hello",
      resume_session_id: nil,
      repo: nil,
      mcp: %HelmsmanProtocol.RunSpec.MCP{
        url: "http://localhost:49999/mcp",
        token: "hmr_run_token"
      },
      limits: %HelmsmanProtocol.RunSpec.Limits{timeout_ms: 10_000, idle_timeout_ms: 5_000},
      trigger: %HelmsmanProtocol.RunSpec.Trigger{kind: "manual", reason: nil, feedback_id: nil}
    }
  end

  def eventually(fun, remaining \\ 200) do
    if fun.() do
      :ok
    else
      if remaining == 0, do: raise("condition did not become true")
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end

  def alive?(pid),
    do: elem(System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true), 1) == 0

  def scenario!(path, text) do
    File.write!(path, text)
    path
  end
end

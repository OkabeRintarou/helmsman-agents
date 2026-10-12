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
    previous = System.get_env("HELMSMAN_HOME")
    System.put_env("HELMSMAN_HOME", context.tmp_dir)
    Paths.ensure!()

    on_exit(fn ->
      if previous,
        do: System.put_env("HELMSMAN_HOME", previous),
        else: System.delete_env("HELMSMAN_HOME")
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

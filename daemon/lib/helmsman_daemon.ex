defmodule HelmsmanDaemon do
  @moduledoc "Helmsman execution daemon; explicitly started by CLI or tests."
  alias HelmsmanDaemon.{
    Cleanup,
    Config,
    Connection,
    Detector,
    Env,
    Janitor,
    Paths,
    Runs,
    StateStore
  }

  def start_daemon(opts \\ []) do
    opts = Keyword.put(opts, :codex_hint_once, :atomics.new(1, []))
    Env.scrub_process!()
    Paths.ensure!()
    security_notice()

    children = [
      {Config, opts},
      {StateStore, opts},
      {Detector, opts},
      {Registry, keys: :unique, name: HelmsmanDaemon.RunRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: HelmsmanDaemon.RunSupervisor},
      {Runs, opts},
      {Cleanup, opts},
      {Connection, opts},
      {Janitor, opts}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: HelmsmanDaemon.Supervisor)
  end

  def security_notice do
    path = Path.join(Paths.state(), ".security_notice_shown")

    unless File.exists?(path) do
      IO.puts("Agent 以守护进程的系统用户身份执行，能读写该用户能访问的一切，包括守护进程令牌与其他任务目录。建议用专用的、没有任何 GitHub 凭据的系统用户运行。")
      File.write!(path, "shown\n")
      File.chmod!(path, 0o600)
    end
  end
end

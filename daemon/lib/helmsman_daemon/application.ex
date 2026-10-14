defmodule HelmsmanDaemon.Application do
  @moduledoc false
  use Application
  alias HelmsmanDaemon.{CLI, Exec, Release}

  @impl true
  def start(_type, _args) do
    # The installed binary boots this release directly: run the CLI with the
    # binary's arguments, then stop the VM with the command's exit code. The CLI
    # starts erlexec itself; mix runs (and tests) get it right away.
    children =
      if Release.standalone?() do
        [Supervisor.child_spec({Task, &main/0}, restart: :temporary, shutdown: 5_000)]
      else
        :ok = Exec.ensure_started()
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: HelmsmanDaemon.ApplicationSupervisor
    )
  end

  # SIGTERM from the service manager stops the VM: stop the daemon tree first,
  # while erlexec still runs, so workers interrupt their CLIs and status.json
  # is removed.
  @impl true
  def prep_stop(state) do
    HelmsmanDaemon.stop_daemon()
    state
  end

  defp main do
    # A daemon tree exiting with :shutdown must reach the CLI as a DOWN message.
    Process.flag(:trap_exit, true)
    # Talk to the VM's standard I/O directly: relayed by the application master,
    # a write to a closed standard output (`| head`) never returns.
    if user = Process.whereis(:user), do: Process.group_leader(self(), user)

    code =
      try do
        CLI.run(Release.argv())
      rescue
        error ->
          # Standard output closed by the reader (`| head`) ends quietly, like SIGPIPE.
          if match?(%ErlangError{original: :terminated}, error) do
            141
          else
            IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
            1
          end
      catch
        kind, reason ->
          IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
          1
      end

    # A one-shot command halts right away: a graceful stop would hang on a
    # standard output that was closed early (`helmsman daemon status | head`).
    # After a daemon run, stop gracefully (a SIGTERM stop is already under way).
    if HelmsmanDaemon.started?() do
      System.stop(code)
    else
      flush_logs()
      System.halt(code)
    end
  end

  # Writes queued log messages (bounded: the output may be gone).
  defp flush_logs do
    task =
      Task.async(fn -> Enum.each(:logger.get_handler_ids(), &:logger_std_h.filesync/1) end)

    Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
  end
end

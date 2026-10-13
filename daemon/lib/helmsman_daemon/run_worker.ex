defmodule HelmsmanDaemon.RunWorker do
  @moduledoc "One temporary worker per run, from workspace preparation to confirmed completion."
  use GenServer, restart: :temporary
  require Logger

  alias HelmsmanDaemon.{
    Adapter,
    Env,
    EventBuffer,
    Exec,
    Git,
    GitFinalizer,
    GitWorkspace,
    LineBuffer,
    Paths,
    ProcGroup,
    RepoCache,
    StateStore,
    Workspace
  }

  alias HelmsmanProtocol.Event
  alias HelmsmanProtocol.Reply
  alias HelmsmanProtocol.Report

  def start_link({spec, opts}), do: GenServer.start_link(__MODULE__, {spec, opts})

  @impl true
  def init({spec, opts}) do
    Registry.register(HelmsmanDaemon.RunRegistry, spec.run_id, %{last_seq: 0, pgid: nil})

    state = %{
      spec: spec,
      opts: opts,
      adapter: Keyword.get(opts, :adapter, Adapter.find(spec.agent.provider)),
      reporter:
        Keyword.get(
          opts,
          :reporter,
          Application.get_env(:helmsman_daemon, :reporter, HelmsmanDaemon.Connection)
        ),
      adapter_state: nil,
      adapter_aborted?: false,
      launch: nil,
      pgid: nil,
      exec_pid: nil,
      cli_guardian: nil,
      buffer: EventBuffer.new(),
      streams: %{stdout: "", stderr: ""},
      stdout_buffer: LineBuffer.new(),
      max_line_bytes: nil,
      reports: %{},
      phase: :prepare,
      stop_reason: nil,
      idle_timer: nil,
      timeout_timer: nil,
      kill_timer: nil,
      result: nil,
      last_error: "",
      proc_group: Keyword.get(opts, :proc_group, ProcGroup),
      members: [],
      snapshot_at: 0,
      group_kill_at: nil,
      group_deadline: nil,
      preserve_record?: false,
      retries: 0,
      git_workspace: nil,
      worktree_lock: nil,
      finalized?: false,
      prepare_events: []
    }

    Process.send_after(self(), :tick, 100)
    {:ok, state, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    id = state.spec.run_id

    :ok =
      StateStore.write(id, %{
        os_pid: nil,
        pgid: nil,
        proc_start: nil,
        started_at: DateTime.utc_now()
      })

    run_dir = Paths.private_dir!(Paths.run(id))
    Paths.private_dir!(Path.join(run_dir, "tmp"))

    {workspace, state} = prepare_workspace(state, run_dir)

    result =
      with {:ok, work_dir} <- workspace,
           {:ok, adapter} <- require_adapter(state.adapter),
           {:ok, launch} <- adapter.prepare(state.spec, run_dir, work_dir) do
        {:ok, adapter, launch, work_dir}
      end

    case result do
      {:ok, adapter, launch, work_dir} ->
        state = %{
          state
          | adapter: adapter,
            launch: launch,
            adapter_state: adapter.init_state(state.spec),
            max_line_bytes:
              if(function_exported?(adapter, :max_line_bytes, 0),
                do: adapter.max_line_bytes(),
                else: nil
              ),
            opts: Keyword.put(state.opts, :work_dir, work_dir),
            phase: :starting
        }

        {:noreply, report(state, :starting, %Report.Starting{run_id: id})}

      {:error, {reason, error}} ->
        {:noreply, finish_failure(state, reason, error)}
    end
  end

  def handle_continue(:finalize, state) do
    {result, events} =
      GitFinalizer.finish(
        state.git_workspace,
        state.spec,
        state.reporter,
        state.result,
        state.opts
      )

    RepoCache.release(state.worktree_lock)
    state = %{state | result: result, finalized?: true, worktree_lock: nil}

    state =
      if Process.get({GitFinalizer, :terminated}, false),
        do: stop_cli(state, :terminate),
        else: state

    state = if state.stop_reason == :terminate, do: state, else: enqueue(state, events)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) when reason in [:shutdown, :normal] do
    if reason == :shutdown and not is_nil(state.pgid) and not state.preserve_record? do
      case StateStore.read(state.spec.run_id) do
        {:ok, record} -> StateStore.kill_record(record)
        _ -> :ok
      end
    end

    Workspace.cleanup(state.spec.run_id)
    if state.worktree_lock, do: RepoCache.release(state.worktree_lock)
    unless state.preserve_record?, do: StateStore.delete(state.spec.run_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp prepare_workspace(%{spec: %{repo: nil}} = state, run_dir),
    do: {Workspace.prepare(state.spec, run_dir), state}

  defp prepare_workspace(state, run_dir) do
    lock = RepoCache.acquire_worktree(GitWorkspace.worktree_path(state.spec))
    state = %{state | worktree_lock: lock}

    opts =
      Keyword.merge(state.opts,
        worktree_locked?: true,
        server_url: server_url(state),
        renew_token: fn id -> GitFinalizer.renew(id, state.reporter, 30_000) end,
        after_fetch: fn workspace ->
          GitFinalizer.prepare(workspace, state.spec, state.reporter)
        end
      )

    case Workspace.prepare_git(state.spec, run_dir, opts) do
      {:ok, workspace} ->
        {{:ok, workspace.path},
         %{state | git_workspace: workspace, prepare_events: workspace.events}}

      error ->
        {error, state}
    end
  end

  defp require_adapter(nil), do: {:error, {:cli_missing, "No adapter for requested provider"}}
  defp require_adapter(adapter), do: {:ok, adapter}

  @impl true
  def handle_cast({:stop, reason}, state), do: {:noreply, stop_cli(state, reason)}

  @impl true
  def handle_info({stream, pid, data}, %{pgid: pid} = state) when stream in [:stdout, :stderr] do
    File.write!(Path.join(Paths.run(state.spec.run_id), "raw.log"), data, [:append])

    state =
      if state.phase == :running and is_nil(state.stop_reason) and data != "",
        do: reset_idle(state),
        else: state

    {:noreply, consume(state, stream, data)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{exec_pid: pid} = state),
    do: {:noreply, exited(state, exit_code(reason))}

  def handle_info({:report_result, ref, result}, state) do
    case Map.pop(state.reports, ref) do
      {nil, _} -> {:noreply, state}
      {entry, reports} -> on_reply(entry.kind, result, %{state | reports: reports})
    end
  end

  def handle_info({:report_rejected, _kind, _reason}, %{phase: :finished} = state) do
    Logger.error("Finished report rejected for run #{state.spec.run_id}")
    cleanup(state)
  end

  def handle_info({:report_rejected, _kind, reason}, state) do
    state = %{
      state
      | buffer: EventBuffer.discard(state.buffer),
        reports: %{},
        result: failed(:unknown, "daemon report rejected: #{safe_reason(reason)}"),
        stop_reason: :rejected
    }

    {:noreply, stop_cli(state, :rejected)}
  end

  def handle_info(:timeout, state), do: {:noreply, stop_cli(state, :timeout)}

  def handle_info(
        {:timeout, timer, :idle_timeout},
        %{idle_timer: timer, phase: :running, stop_reason: nil} = state
      ),
      do: {:noreply, stop_cli(state, :stalled)}

  def handle_info(:kill, state) do
    state = if state.pgid, do: signal_cli(state, 9), else: state
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 100)
    state = state |> refresh_members() |> resubmit()
    tick(state)
  end

  def handle_info(_, state), do: {:noreply, state}

  defp on_reply(:starting, {:ok, %Reply.Starting{action: :abort}}, state), do: cleanup(state)

  defp on_reply(:starting, {:ok, %Reply.Starting{action: :proceed}}, %{stop_reason: nil} = state),
    do: {:noreply, launch(state)}

  defp on_reply(:starting, {:ok, _}, state), do: cleanup(state)

  defp on_reply(:events, {:ok, %Reply.Events{acked_seq: seq}}, state) do
    {:noreply, %{state | buffer: EventBuffer.ack(state.buffer, seq)}}
  end

  defp on_reply(:finished, {:ok, _}, state), do: cleanup(state)

  defp on_reply(_kind, {:error, %{reason: reason}}, state)
       when reason in [:not_found, :wrong_state],
       do: {:noreply, stop_cli(state, :terminate)}

  defp on_reply(_kind, {:error, %{reason: :invalid_payload, message: reason}}, state),
    do: handle_info({:report_rejected, :invalid_payload, reason}, state)

  defp on_reply(:events, {:error, _}, state),
    do: {:noreply, %{state | buffer: EventBuffer.failed(state.buffer)}}

  defp on_reply(kind, {:error, _}, state) do
    {:noreply, retry_report(kind, state)}
  end

  defp on_reply(_kind, _result, state), do: {:noreply, state}

  defp launch(state) do
    {env, warnings} = environment(state)

    options = [
      :stdin,
      {:stdout, self()},
      {:stderr, self()},
      {:group, 0},
      :kill_group,
      {:cd, Keyword.fetch!(state.opts, :work_dir)},
      {:env, env},
      :monitor
    ]

    case launch_cli(state, options) do
      {:ok, exec_pid, pid, guardian} ->
        start =
          case Exec.proc_start(pid) do
            {:ok, value} -> value
            _ -> nil
          end

        :ok =
          StateStore.write(state.spec.run_id, %{
            os_pid: pid,
            pgid: pid,
            proc_start: start,
            started_at: DateTime.utc_now()
          })

        {:ok, members} = state.proc_group.snapshot(pid)
        Registry.update_value(HelmsmanDaemon.RunRegistry, state.spec.run_id, &%{&1 | pgid: pid})

        state = %{
          state
          | pgid: pid,
            exec_pid: exec_pid,
            cli_guardian: guardian,
            members: members,
            snapshot_at: System.monotonic_time(:millisecond),
            phase: :running,
            timeout_timer: Process.send_after(self(), :timeout, state.spec.limits.timeout_ms)
        }

        state =
          state
          |> persist_members()
          |> reset_idle()
          |> enqueue(state.prepare_events ++ warnings ++ state.launch.events)

        state =
          report(state, :started, %Report.Started{
            run_id: state.spec.run_id,
            session_id: state.spec.resume_session_id
          })

        if state.launch.stdin, do: :exec.send(pid, IO.iodata_to_binary(state.launch.stdin))
        if state.launch.close_stdin?, do: :exec.send(pid, :eof)
        state

      {:error, error} ->
        finish_failure(state, :cli_error, "CLI launch failed: #{inspect(error)}")
    end
  end

  defp launch_cli(%{git_workspace: nil} = state, options) do
    Exec.run_cli(state.launch.argv, options)
  end

  defp launch_cli(state, options), do: Exec.start_cli(state.launch.argv, options, state.opts)

  defp environment(state) do
    {reserved, allowed} =
      Enum.split_with(state.spec.agent.env, fn {key, _} ->
        String.starts_with?(key, "HELMSMAN_")
      end)

    warnings =
      Enum.map(reserved, fn {key, _} ->
        {:status, %{level: :warning, message: "Ignored reserved environment variable #{key}"}}
      end)

    own = %{
      "HELMSMAN_RUN_TOKEN" => state.spec.mcp.token,
      "HELMSMAN_SERVER_URL" => server_url(state),
      "HELMSMAN_RUN_ID" => to_string(state.spec.run_id),
      "HELMSMAN_TASK" => if(state.spec.task, do: state.spec.task.ident, else: ""),
      "TMPDIR" => Path.join(Paths.run(state.spec.run_id), "tmp")
    }

    env =
      Keyword.get(state.opts, :base_env, System.get_env())
      |> Env.child()
      |> Map.put("GIT_TERMINAL_PROMPT", "0")
      |> Map.merge(Map.new(allowed))
      |> Map.merge(own)
      |> Map.merge(Map.new(state.launch.env))
      |> Map.merge(
        if(state.spec.repo, do: Git.identity(state.spec.agent.name, server_url(state)), else: %{})
      )
      |> Map.delete("HELMSMAN_GIT_TOKEN")

    {Enum.to_list(env), warnings}
  end

  defp server_url(state),
    do:
      Keyword.get(
        state.opts,
        :server_url,
        URI.to_string(%{URI.parse(state.spec.mcp.url) | path: nil, query: nil, fragment: nil})
      )

  defp consume(%{adapter_aborted?: true} = state, _stream, _data), do: state

  defp consume(%{max_line_bytes: limit} = state, :stdout, data) when is_integer(limit) do
    {lines, buffer} = LineBuffer.push(state.stdout_buffer, data, limit)
    state = %{state | stdout_buffer: buffer}

    Enum.reduce(lines, state, fn
      :overflow, acc -> output_overflow(acc, limit)
      line, acc -> deliver(acc, :stdout, line)
    end)
  end

  defp consume(state, stream, data) do
    joined = state.streams[stream] <> data
    {lines, tail} = split_lines(joined)
    state = %{state | streams: Map.put(state.streams, stream, tail)}

    Enum.reduce(lines, state, fn {line, oversized?}, acc ->
      acc =
        if oversized?,
          do:
            enqueue(acc, [
              {:status,
               %{level: :warning, message: "CLI output line exceeded 1 MB and was split"}}
            ]),
          else: acc

      deliver(acc, stream, line)
    end)
  end

  defp output_overflow(state, limit) do
    message =
      "CLI output message exceeded #{limit / 1_048_576} MB; the turn result could not be read"

    state = enqueue(state, [{:status, %{level: :warning, message: message}}])

    if state.stop_reason do
      state
    else
      state |> stop_cli(:output_overflow) |> Map.put(:result, failed(:cli_error, message))
    end
  end

  defp deliver(state, :stdout, _line) when state.stop_reason == :output_overflow, do: state

  defp deliver(%{adapter_aborted?: true} = state, _stream, _line), do: state

  defp deliver(state, stream, line) do
    {events, actions, adapter_state} =
      state.adapter.handle_output(stream, line, state.adapter_state)

    state = %{
      state
      | adapter_state: adapter_state,
        last_error: if(stream == :stderr, do: line, else: state.last_error)
    }

    state = enqueue(state, events)

    case Enum.find(actions, &match?({:abort, _, _}, &1)) do
      {:abort, reason, message} -> abort_adapter(state, reason, message)
      nil -> perform_actions(state, actions)
    end
  end

  defp perform_actions(%{stop_reason: reason} = state, _actions) when not is_nil(reason),
    do: state

  defp perform_actions(state, actions) do
    Enum.each(actions, fn
      :close_stdin -> :exec.send(state.pgid, :eof)
      {:write, bytes} -> :exec.send(state.pgid, IO.iodata_to_binary(bytes))
    end)

    state
  end

  defp abort_adapter(state, reason, message) do
    state = %{state | adapter_aborted?: true}

    if state.stop_reason do
      state
    else
      {reason, message} =
        if reason in HelmsmanProtocol.FailureReason.daemon_reportable() and is_binary(message),
          do: {reason, message},
          else: {:cli_error, "Adapter returned an invalid abort reason or message"}

      state |> stop_cli(:adapter_abort) |> Map.put(:result, failed(reason, message))
    end
  end

  defp split_lines(data), do: split_lines(data, [])

  defp split_lines(data, acc) do
    case :binary.match(data, "\n") do
      {index, 1} when index <= 1_048_576 ->
        <<line::binary-size(^index), _newline, tail::binary>> = data
        split_lines(tail, [{line, false} | acc])

      _ when byte_size(data) > 1_048_576 ->
        <<line::binary-size(1_048_576), tail::binary>> = data
        split_lines(tail, [{line, true} | acc])

      _ ->
        {Enum.reverse(acc), data}
    end
  end

  defp enqueue(state, events) do
    buffer =
      Enum.reduce(events, state.buffer, fn {type, data}, acc ->
        EventBuffer.append(acc, type, data)
      end)

    Registry.update_value(
      HelmsmanDaemon.RunRegistry,
      state.spec.run_id,
      &%{&1 | last_seq: buffer.next_seq - 1}
    )

    %{state | buffer: buffer}
  end

  defp reset_idle(state) do
    cancel_timer(state.idle_timer)

    %{
      state
      | idle_timer: :erlang.start_timer(state.spec.limits.idle_timeout_ms, self(), :idle_timeout)
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp stop_cli(%{stop_reason: previous} = state, reason)
       when not is_nil(previous) and reason in [:cancel, :timeout, :stalled],
       do: state

  defp stop_cli(%{phase: phase} = state, reason)
       when phase in [:draining, :finished, :collecting] do
    if reason == :terminate,
      do: %{state | stop_reason: reason, buffer: EventBuffer.discard(state.buffer), reports: %{}},
      else: state
  end

  defp stop_cli(%{pgid: nil} = state, reason) do
    %{
      state
      | stop_reason: reason,
        phase: :draining,
        buffer: EventBuffer.discard(state.buffer),
        reports: %{},
        result: state.result || stopped_result(reason)
    }
  end

  defp stop_cli(state, reason) do
    if state.kill_timer do
      %{state | stop_reason: reason}
    else
      state =
        case state.adapter.interrupt(state.adapter_state) do
          :signal ->
            signal_cli(state, 15)

          {:write, bytes} ->
            :exec.send(state.pgid, IO.iodata_to_binary(bytes))
            state
        end

      cancel_timer(state.idle_timer)
      cancel_timer(state.timeout_timer)

      %{
        state
        | stop_reason: reason,
          idle_timer: nil,
          group_kill_at:
            System.monotonic_time(:millisecond) +
              Keyword.get(state.opts, :kill_timeout_ms, 10_000),
          kill_timer:
            Process.send_after(self(), :kill, Keyword.get(state.opts, :kill_timeout_ms, 10_000))
      }
    end
  end

  defp persist_members(state) do
    with {:ok, record} <- StateStore.read(state.spec.run_id) do
      fields =
        record |> Map.put("members", ProcGroup.to_wire(state.members)) |> Map.delete("run_id")

      :ok = StateStore.write(state.spec.run_id, fields)
    end

    state
  end

  defp refresh_members(%{phase: :running, pgid: pgid} = state) when not is_nil(pgid) do
    if System.monotonic_time(:millisecond) - state.snapshot_at >=
         Keyword.get(state.opts, :snapshot_interval_ms, 10_000) do
      signal_cli(state, nil)
    else
      state
    end
  end

  defp refresh_members(state), do: state

  defp signal_cli(state, signal) do
    case state.proc_group.step(state.pgid, state.members, signal) do
      {:ok, group} ->
        %{state | members: group.members, snapshot_at: System.monotonic_time(:millisecond)}
        |> persist_members()

      _ ->
        state
    end
  end

  defp exited(state, status) do
    # This immediate snapshot is trusted under architect decision 17; thereafter continuity is required.
    members =
      case state.proc_group.snapshot(state.pgid) do
        {:ok, current} -> ProcGroup.merge(state.members, current)
        _ -> state.members
      end

    state = %{state | members: members} |> persist_members()

    Enum.each([state.idle_timer, state.timeout_timer], &cancel_timer/1)

    state =
      Enum.reduce([:stdout, :stderr], state, fn stream, acc ->
        pending? = stream_pending?(acc, stream)

        if pending?, do: consume(acc, stream, "\n"), else: acc
      end)

    result =
      if state.stop_reason,
        do: state.result || stopped_result(state.stop_reason),
        else: adapter_result(state, status)

    buffer =
      if state.stop_reason in [:rejected, :terminate],
        do: EventBuffer.discard(state.buffer),
        else: state.buffer

    now = System.monotonic_time(:millisecond)
    kill_at = state.group_kill_at || now + Keyword.get(state.opts, :kill_timeout_ms, 10_000)
    state = signal_cli(state, 15)

    %{
      state
      | phase: :collecting,
        buffer: buffer,
        result: result,
        group_kill_at: kill_at,
        group_deadline: kill_at + Keyword.get(state.opts, :group_cleanup_timeout_ms, 5_000),
        idle_timer: nil,
        timeout_timer: nil
    }
  end

  defp stream_pending?(%{max_line_bytes: limit} = state, :stdout) when is_integer(limit),
    do: LineBuffer.pending?(state.stdout_buffer)

  defp stream_pending?(state, stream), do: state.streams[stream] != ""

  defp exit_code(:normal), do: 0

  defp exit_code({:exit_status, status}) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _, _} -> 128
    end
  end

  defp exit_code(_), do: 1

  defp adapter_result(state, status) do
    {result, metadata} = state.adapter.finish(status, state.adapter_state)

    fields =
      case result do
        :succeeded -> %{status: :succeeded, failure_reason: nil, error: nil}
        {:failed, reason, error} -> failed(reason, error)
      end

    Map.merge(fields, metadata)
  end

  defp stopped_result(:cancel), do: %{status: :cancelled, failure_reason: nil, error: nil}

  defp stopped_result(reason) when reason in [:timeout, :stalled],
    do: failed(reason, "CLI stopped: #{reason}")

  defp stopped_result(_), do: failed(:unknown, "CLI terminated")
  defp failed(reason, error), do: %{status: :failed, failure_reason: reason, error: error}

  defp finish_failure(state, reason, error),
    do: %{state | phase: :draining, result: failed(reason, error)}

  defp safe_reason(reason) when is_binary(reason), do: elem(Event.truncate(reason, 1_024), 0)
  defp safe_reason(_), do: "invalid_payload"

  defp tick(%{phase: :collecting} = state) do
    now = System.monotonic_time(:millisecond)
    signal = if now >= state.group_kill_at, do: 9, else: nil

    case state.proc_group.step(state.pgid, state.members, signal) do
      {:ok, %{empty?: true}} ->
        cancel_timer(state.kill_timer)
        Exec.release_cli(state.cli_guardian)
        tick(%{state | phase: :draining, kill_timer: nil, cli_guardian: nil})

      {:ok, group} ->
        state = %{state | members: group.members} |> persist_members()
        if now >= state.group_deadline, do: group_cleanup_failed(state), else: {:noreply, state}

      _ ->
        if now >= state.group_deadline, do: group_cleanup_failed(state), else: {:noreply, state}
    end
  end

  defp tick(
         %{
           phase: :draining,
           git_workspace: workspace,
           pgid: pgid,
           finalized?: false,
           preserve_record?: false
         } = state
       )
       when not is_nil(workspace) and not is_nil(pgid),
       do: {:noreply, state, {:continue, :finalize}}

  defp tick(%{phase: :draining, stop_reason: :terminate} = state), do: cleanup(state)
  defp tick(%{phase: :finished, stop_reason: :terminate} = state), do: cleanup(state)

  defp tick(%{phase: :draining} = state) do
    if EventBuffer.size(state.buffer) == 0 and map_size(state.reports) == 0 do
      fields = Map.merge(%{session_id: nil, summary: nil, usage: nil}, state.result)

      {:noreply,
       report(
         %{state | phase: :finished},
         :finished,
         struct!(Report.Finished, Map.put(fields, :run_id, state.spec.run_id))
       )}
    else
      {:noreply, send_batch(state)}
    end
  end

  defp tick(%{phase: :running} = state), do: {:noreply, send_batch(state)}
  defp tick(state), do: {:noreply, state}

  defp group_cleanup_failed(state) do
    Logger.error("Process group cleanup timed out for run #{state.spec.run_id}; state retained")

    result =
      Map.update(state.result, :error, "process group cleanup timed out", fn error ->
        (error || "") <> "; process group cleanup timed out"
      end)

    tick(%{state | phase: :draining, preserve_record?: true, result: result})
  end

  defp send_batch(state) do
    if map_size(state.reports) == 0 do
      {batch, buffer} = EventBuffer.take_batch(state.buffer)
      state = %{state | buffer: buffer}

      if batch == [],
        do: state,
        else: report(state, :events, %Report.Events{run_id: state.spec.run_id, events: batch})
    else
      state
    end
  end

  defp report(state, kind, payload) do
    ref = state.reporter.report(state.spec.run_id, payload)
    entry = %{kind: kind, payload: payload, at: System.monotonic_time(:millisecond)}
    %{state | reports: Map.put(state.reports, ref, entry)}
  end

  defp resubmit(state) do
    now = System.monotonic_time(:millisecond)
    interval = Keyword.get(state.opts, :report_resubmit_ms, 30_000)

    Enum.reduce(state.reports, state, fn {ref, entry}, acc ->
      if now - entry.at >= interval do
        resubmit_entry(acc, ref, entry)
      else
        acc
      end
    end)
  end

  defp resubmit_entry(state, ref, entry) do
    if state.phase == :finished and state.stop_reason == :rejected and state.retries >= 3 do
      %{state | reports: %{}, phase: :draining, stop_reason: :terminate}
    else
      state = %{state | reports: Map.delete(state.reports, ref), retries: state.retries + 1}
      report(state, entry.kind, entry.payload)
    end
  end

  defp retry_report(:finished, state) do
    if state.stop_reason == :rejected,
      do: %{state | stop_reason: :terminate, phase: :draining},
      else: %{state | phase: :draining}
  end

  defp retry_report(:starting, state),
    do: report(state, :starting, %Report.Starting{run_id: state.spec.run_id})

  defp retry_report(_, state), do: state

  defp cleanup(state) do
    Workspace.cleanup(state.spec.run_id)
    unless state.preserve_record?, do: StateStore.delete(state.spec.run_id)
    {:stop, :normal, state}
  end
end

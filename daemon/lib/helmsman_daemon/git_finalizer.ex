defmodule HelmsmanDaemon.GitFinalizer do
  @moduledoc "Commit, durable push intentions and confirmed push reports for repository runs."
  alias HelmsmanDaemon.{Git, GitLedger, GitWorkspace, RepoCache}
  alias HelmsmanProtocol.{Event, Report}

  def prepare(state, spec, reporter) do
    state = reconcile(state, spec, reporter, deadline(state, 30_000))
    ledger = GitLedger.read(spec)

    inherit =
      if GitWorkspace.dirty?(state) or
           not GitWorkspace.ancestor?(state, "HEAD", state.remote_base),
         do: ledger["inherit"],
         else: []

    GitLedger.write(spec, %{ledger | "inherit" => Enum.uniq(inherit ++ [spec.run_id])})
    state
  catch
    {:git_finish, output} -> throw({:git_prepare, :ledger, output})
  end

  def renew(run_id, reporter, timeout) do
    case request(reporter, run_id, %Report.GitToken{run_id: run_id}, now() + timeout, 30_000) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        {:ok, %{token: token, expires_at: expires_at}}

      result ->
        result
    end
  end

  def finish(state, spec, reporter, result, opts) do
    end_at = now() + Keyword.get(opts, :finalize_timeout_ms, 300_000)

    state = %{
      state
      | events: [],
        git: %{state.git | opts: Keyword.put(state.git.opts, :deadline, end_at)}
    }

    {outcome, state} = finalize(state, spec, reporter, end_at)
    {apply_outcome(result, outcome, spec.repo.branch), state.events}
  rescue
    error in [ArgumentError, File.Error, MatchError] ->
      {apply_outcome(result, {:failed, Git.redact(Exception.message(error))}, spec.repo.branch),
       []}
  catch
    {:git_finish, output} ->
      {apply_outcome(result, {:failed, output}, spec.repo.branch), []}

    {:git_prepare, _reason, output} ->
      {apply_outcome(result, {:failed, output}, spec.repo.branch), []}
  end

  defp finalize(state, spec, reporter, end_at) do
    state = auto_commit(state, spec)
    scope = local_scope(state)

    {outcome, state} =
      cond do
        GitWorkspace.ancestor?(state, "HEAD", state.remote_base) ->
          {:none, state}

        # Revoked before delivery: never touch the user's repository; the commits
        # stay in the task worktree and the ledger for a later run.
        match?({:error, _}, scope) ->
          {{:failed, elem(scope, 1)}, state}

        true ->
          deliver(state, spec, reporter, end_at)
      end

    state =
      if scope == :ok, do: refresh_and_reconcile(state, spec, reporter, end_at), else: state

    settle(state, spec, outcome, end_at)
  end

  defp settle(state, spec, outcome, end_at) do
    ledger = GitLedger.read(spec)

    outcome =
      if ledger["outbox"] != [] and now() >= end_at,
        do: {:failed, "push acknowledgement timed out"},
        else: outcome

    if outcome in [:none, :pushed] or match?({:conflict, _, _}, outcome) do
      unless GitWorkspace.dirty?(state), do: GitLedger.write(spec, %{ledger | "inherit" => []})
    end

    {outcome, state}
  end

  # Every fetch, ls-remote and push of a local repository re-reads config.toml first.
  defp local_scope(state) do
    case GitWorkspace.local_access(state) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, message <> "; not delivered, commits are kept in the task worktree"}
    end
  end

  defp deliver(state, spec, reporter, end_at) do
    base =
      if state.remote_branch?,
        do: state.remote_base,
        else: run!(state, ["merge-base", "HEAD", state.remote_base])

    head = run!(state, ["rev-parse", "HEAD"])
    {commits, state} = commits(state, base)

    payload = %{
      "branch" => spec.repo.branch,
      "base_sha" => base,
      "head_sha" => head,
      "rescue_branch" => nil,
      "commits" => commits
    }

    push(state, spec, reporter, payload, spec.repo.branch, 0, false, end_at)
  end

  defp auto_commit(state, spec) do
    cond do
      run!(state, ["diff", "--name-only", "--diff-filter=U"]) != "" ->
        warn(state, "unresolved merge conflicts left in the worktree; not committed")

      GitWorkspace.dirty?(state) ->
        run!(state, ["add", "-A"])

        run!(state, [
          "commit",
          "--no-verify",
          "-m",
          "#{spec.task.ident}: uncommitted changes from run #{spec.run_id}"
        ])

        state

      true ->
        state
    end
  end

  defp commits(state, base) do
    count = String.to_integer(run!(state, ["rev-list", "--count", base <> "..HEAD"]))

    state =
      if count > 250,
        do: warn(state, "push contains #{count} commits; reporting the latest 250"),
        else: state

    commits =
      run!(state, ["log", "--format=%H%x1f%s", "--max-count=250", base <> "..HEAD"])
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [sha, subject] = String.split(line, <<31>>, parts: 2)
        %{"sha" => sha, "subject" => elem(Event.truncate(subject, 1024), 0)}
      end)

    {commits, state}
  end

  defp push(state, spec, reporter, payload, target, attempt, renew?, end_at) do
    if attempt >= 3 or now() >= end_at do
      {{:failed, "push attempts exhausted or finalization timed out"}, state}
    else
      case token(state, spec, reporter, renew?, end_at) do
        {:ok, state} -> push_attempt(state, spec, reporter, payload, target, attempt, end_at)
        _ -> retry(state, spec, reporter, payload, target, attempt, true, end_at)
      end
    end
  end

  defp push_attempt(state, spec, reporter, payload, target, attempt, end_at) do
    case local_scope(state) do
      :ok -> push_command(state, spec, reporter, payload, target, attempt, end_at)
      {:error, message} -> {{:failed, message}, state}
    end
  end

  defp push_command(state, spec, reporter, payload, target, attempt, end_at) do
    entry = intent(spec, payload, target)

    args =
      ["push"] ++
        GitWorkspace.transport(state, :receive) ++
        Keyword.get(state.git.opts, :push_args, []) ++
        [state.origin, "HEAD:refs/heads/" <> target]

    case Git.run(args, state.path, state.git) do
      {:ok, _} ->
        pushed(state, spec, reporter, entry, end_at)

      {:error, {_reason, output}} ->
        push_error(state, spec, reporter, target, attempt, entry, output, end_at)
    end
  end

  defp push_error(state, spec, reporter, target, attempt, entry, output, end_at) do
    payload = Map.take(entry, ~w(branch base_sha head_sha rescue_branch commits))

    probe = remote_head(state, target, payload["head_sha"], end_at)

    cond do
      probe == :landed ->
        pushed(state, spec, reporter, entry, end_at)

      Git.classify(output) == :rejected and target == spec.repo.branch ->
        discard_intent(spec, entry)
        state = checked_out_note(state, spec, output)
        rescue_branch = spec.repo.branch <> "-run-#{spec.run_id}"

        push(
          state,
          spec,
          reporter,
          %{payload | "rescue_branch" => rescue_branch},
          rescue_branch,
          attempt,
          false,
          end_at
        )

      true ->
        # Failed verification leaves an intention for the next successful fetch.
        if probe == :absent, do: discard_intent(spec, entry)
        state = warn(state, "push attempt failed: #{output}")
        retry(state, spec, reporter, payload, target, attempt, true, end_at)
    end
  end

  defp checked_out_note(%{local: %{name: name}} = state, spec, output) do
    if Git.checked_out?(output),
      do: %{
        state
        | delivery_note:
            "The task branch #{spec.repo.branch} is checked out in #{name}; check out another branch there so the next delivery can update it."
      },
      else: state
  end

  defp checked_out_note(state, _spec, _output), do: state

  defp retry(state, spec, reporter, payload, target, attempt, renew?, end_at) do
    if attempt < 2 do
      delay = Enum.at(Keyword.get(state.git.opts, :push_backoff_ms, [5_000, 15_000]), attempt)

      receive do
        {:"$gen_cast", {:stop, :terminate}} -> Process.put({__MODULE__, :terminated}, true)
      after
        min(delay, max(end_at - now(), 0)) -> :ok
      end
    end

    push(state, spec, reporter, payload, target, attempt + 1, renew?, end_at)
  end

  defp token(%{local: local} = state, _spec, _reporter, _renew?, _end_at) when not is_nil(local),
    do: {:ok, state}

  defp token(state, spec, reporter, renew?, end_at) do
    expires = Keyword.get(state.git.opts, :token_expires_at, spec.repo.git_token_expires_at)

    if renew? or DateTime.diff(expires, DateTime.utc_now()) < 300 do
      case renew(spec.run_id, reporter, min(30_000, max(end_at - now(), 0))) do
        {:ok, %{token: token, expires_at: expires}} ->
          {:ok,
           %{
             state
             | git: %{
                 state.git
                 | token: token,
                   opts: Keyword.put(state.git.opts, :token_expires_at, expires)
               }
           }}

        error ->
          error
      end
    else
      {:ok, state}
    end
  end

  defp intent(spec, payload, target) do
    ledger = GitLedger.read(spec)

    runs =
      Enum.uniq([spec.run_id | ledger["inherit"]])
      |> Enum.map(&%{"run_id" => &1, "acked" => false})

    entry = Map.merge(payload, %{"target" => target, "runs" => runs})
    GitLedger.write(spec, %{ledger | "outbox" => Enum.uniq(ledger["outbox"] ++ [entry])})
    entry
  end

  defp discard_intent(spec, entry) do
    ledger = GitLedger.read(spec)
    GitLedger.write(spec, %{ledger | "outbox" => List.delete(ledger["outbox"], entry)})
  end

  defp pushed(state, spec, reporter, entry, end_at) do
    state = acknowledge(state, spec, reporter, entry, end_at)

    outcome =
      if entry["rescue_branch"],
        do: {:conflict, entry["rescue_branch"], state.delivery_note},
        else: :pushed

    {outcome, state}
  end

  defp acknowledge(state, spec, reporter, entry, end_at) do
    Enum.reduce_while(entry["runs"], state, fn run, current ->
      acknowledge_run(current, spec, reporter, entry, run, end_at)
    end)
  end

  defp acknowledge_run(state, _spec, _reporter, _entry, %{"acked" => true}, _end_at),
    do: {:cont, state}

  defp acknowledge_run(state, spec, reporter, entry, run, end_at) do
    {:ok, payload} =
      Report.Pushed.from_wire(
        Map.put(
          Map.take(entry, ~w(branch base_sha head_sha rescue_branch commits)),
          "run_id",
          run["run_id"]
        )
      )

    response =
      request(
        reporter,
        run["run_id"],
        payload,
        end_at,
        Keyword.get(state.git.opts, :report_resubmit_ms, 30_000)
      )

    case response do
      {:error, :timeout} ->
        {:halt, state}

      response ->
        mark_acked(spec, entry, run["run_id"])

        state =
          if match?({:ok, _}, response),
            do: state,
            else:
              warn(state, "pushed report for run #{run["run_id"]} rejected: #{inspect(response)}")

        {:cont, state}
    end
  end

  defp mark_acked(spec, entry, id) do
    ledger = GitLedger.read(spec)

    outbox =
      Enum.map(ledger["outbox"], fn item ->
        if Map.drop(item, ["runs"]) == Map.drop(entry, ["runs"]),
          do: %{
            item
            | "runs" =>
                Enum.map(item["runs"], fn run ->
                  if run["run_id"] == id, do: %{run | "acked" => true}, else: run
                end)
          },
          else: item
      end)
      |> Enum.reject(fn item -> Enum.all?(item["runs"], & &1["acked"]) end)

    GitLedger.write(spec, %{ledger | "outbox" => outbox})
  end

  defp reconcile(state, spec, reporter, end_at) do
    Enum.reduce(GitLedger.read(spec)["outbox"], state, fn entry, current ->
      ref = "refs/remotes/origin/" <> entry["target"]

      if landed?(current, entry["head_sha"], ref) do
        acknowledge(current, spec, reporter, entry, end_at)
      else
        ledger = GitLedger.read(spec)
        ids = Enum.map(entry["runs"], & &1["run_id"])

        GitLedger.write(spec, %{
          ledger
          | "outbox" => List.delete(ledger["outbox"], entry),
            "inherit" => Enum.uniq(ledger["inherit"] ++ ids)
        })

        current
      end
    end)
  end

  defp landed?(state, head, ref) do
    case Git.run(["rev-parse", "--verify", "--quiet", ref], state.cache, state.git) do
      {:ok, _} -> GitWorkspace.ancestor?(state, head, ref)
      {:error, {{:exit_status, 256}, _}} -> false
      {:error, {_, output}} -> throw({:git_finish, output})
    end
  end

  defp refresh_and_reconcile(state, spec, reporter, end_at) do
    case RepoCache.with_repo_lock_until(state.cache, end_at, fn ->
           fetch_and_reconcile(state, spec, reporter, end_at)
         end) do
      {:error, :timeout} -> state
      current -> current
    end
  end

  defp fetch_and_reconcile(state, spec, reporter, end_at) do
    if local_scope(state) == :ok,
      do: fetch_then_reconcile(state, spec, reporter, end_at),
      else: state
  end

  defp fetch_then_reconcile(state, spec, reporter, end_at) do
    case Git.run(
           ["fetch"] ++ GitWorkspace.transport(state, :upload) ++ ["--prune", "origin"],
           state.cache,
           state.git
         ) do
      {:ok, _} -> reconcile(state, spec, reporter, end_at)
      _ -> state
    end
  end

  # Without access the push may or may not have landed: keep the intention.
  defp remote_head(state, target, head, end_at) do
    if local_scope(state) == :ok, do: probe_head(state, target, head, end_at), else: :unknown
  end

  defp probe_head(state, target, head, end_at) do
    probe = %{state.git | opts: Keyword.put(state.git.opts, :deadline, end_at)}

    args =
      ["ls-remote"] ++
        GitWorkspace.transport(state, :upload) ++ [state.origin, "refs/heads/" <> target]

    case Git.run(args, state.path, probe) do
      {:ok, output} -> if List.first(String.split(output)) == head, do: :landed, else: :absent
      _ -> :unknown
    end
  end

  defp request(reporter, id, payload, end_at, interval) do
    if now() >= end_at do
      {:error, :timeout}
    else
      ref = reporter.report(id, payload)
      await_request(%{ref => true}, reporter, id, payload, end_at, interval)
    end
  end

  defp await_request(refs, reporter, id, payload, end_at, interval) do
    receive do
      {:report_result, ref, {:ok, _} = result} when is_map_key(refs, ref) ->
        result

      {:report_result, ref, {:error, %{reason: reason}} = result}
      when is_map_key(refs, ref) and reason in [:not_found, :wrong_state, :invalid_payload] ->
        result

      {:report_result, ref, _} when is_map_key(refs, ref) ->
        await_request(refs, reporter, id, payload, end_at, interval)

      {:report_rejected, _, reason} ->
        {:error, reason}

      {:"$gen_cast", {:stop, :terminate}} ->
        Process.put({__MODULE__, :terminated}, true)
        await_request(refs, reporter, id, payload, end_at, interval)
    after
      min(interval, max(end_at - now(), 0)) ->
        resubmit_request(refs, reporter, id, payload, end_at, interval)
    end
  end

  defp resubmit_request(refs, reporter, id, payload, end_at, interval) do
    if now() >= end_at do
      {:error, :timeout}
    else
      ref = reporter.report(id, payload)
      await_request(Map.put(refs, ref, true), reporter, id, payload, end_at, interval)
    end
  end

  defp run!(state, args) do
    case Git.run(args, state.path, state.git) do
      {:ok, output} -> String.trim(output)
      {:error, {_, output}} -> throw({:git_finish, output})
    end
  end

  defp apply_outcome(result, outcome, branch) do
    {reason, error} =
      case outcome do
        {:failed, error} ->
          {:push_failed, "push failed: #{error}"}

        {:conflict, rescue_branch, note} ->
          {:push_conflict,
           Enum.join(
             Enum.reject(
               ["push to #{branch} was rejected; changes were pushed to #{rescue_branch}", note],
               &is_nil/1
             ),
             "\n"
           )}

        _ ->
          {nil, nil}
      end

    cond do
      is_nil(reason) ->
        result

      result.status == :succeeded ->
        Map.merge(result, %{status: :failed, failure_reason: reason, error: error})

      true ->
        Map.update(
          result,
          :error,
          error,
          &Enum.join(Enum.reject([&1, error], fn x -> x in [nil, ""] end), "; ")
        )
    end
  end

  defp warn(state, message),
    do: %{state | events: state.events ++ [{:status, %{level: :warning, message: message}}]}

  defp deadline(state, timeout),
    do: min(Keyword.fetch!(state.git.opts, :deadline), now() + timeout)

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule Helmsman.Runs.Claim do
  @moduledoc """
  A daemon claims queued runs (designs/13 §4.1, `add-run-lifecycle`
  decisions 3, 24), in one transaction that never waits for a lock other
  than the run rows it skips:

    1. the daemon lock (`Locks.try_daemon/1`; taken: nothing) and the
       daemon row `FOR SHARE` in the connection's authorization epoch;
    2. free slots: `max_concurrency` minus its `claimed`, `running` and
       `cancelling` runs;
    3. its runtimes that are online, not disabled, in a workspace it
       serves and where its user is a member or above;
    4. candidates in batches of 50 (at most 200 looked at): `queued`, due
       (`not_before`), by priority, then age, `FOR UPDATE SKIP LOCKED`;
    5. per candidate, only `try` locks: the workspace maintenance lock
       (shared), the task lock (the task may have no other active run),
       then, with `SKIP LOCKED`, the membership rows of the users the check
       reads (by ID), the actor row, the identity and `squads` rows of the
       squads the check reads (`add-squads` decision 10), the profile row
       (`FOR UPDATE`: the
       agent's concurrency limit), the task row and the runtime row. A row
       held by a writer leaves the candidate queued; a membership row that
       does not exist is read as no longer a member;
    6. `Helmsman.Runs.Revalidation`, with the steering facts read now
       (`Helmsman.Runs.Steering.facts/1`, `add-run-steering` decision 7):
       invalid → `cancelled` (`obsolete` / `unauthorized`); triggers
       pruned or settled → written back;
    6a. a run there only for assignment triggers
       (`Helmsman.Runs.Triggers.dependency_gated?/1`) on a task with a
       `depends_on`: the graph lock is tried (`Locks.try_graph/1`; taken:
       left queued) and an unsatisfied prerequisite sends it back to
       `deferred` (`add-dependency-dispatch` decision 7);
    7. the repository: a local repository (`Helmsman.Runs.LocalRepo`,
       `add-local-repositories` decision 6) on another machine, removed,
       unavailable or over a connection too old → `failed`
       (`workspace_prepare`); else the GitHub repository
       (`Helmsman.Runs.GitRepo`, `add-daemon-git-workspace` decision 2):
       unavailable → `failed` (`workspace_prepare`); no prefetched push
       token → left queued;
    8. `claimed`, the daemon, `claimed_at`, the capabilities recomputed,
       the repository and task branch, the agent's provider account, a run
       token and the run description (`Helmsman.Runs.Spec`).

  A connection older than `HelmsmanProtocol.provider_account_version/0`
  leaves the runs of agents bound to a provider account queued
  (`add-provider-accounts` decision 4): it would ignore the account and
  bill the user's own CLI configuration.

  Claiming is the only path that locks a run row before other rows; every
  other lock is a `try`, so it never waits in a cycle with task writes or
  configuration changes (designs/01 §4).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Autopilots
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Links
  alias Helmsman.Locks
  alias Helmsman.ProviderAccounts.ProviderAccount
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{GitRepo, Lifecycle, LocalRepo, Run, RunTokens, Spec, Steering, Triggers}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Membership

  @batch 50
  @max_scan 200
  @member_roles [:owner, :admin, :member]

  @doc """
  Claims runs for the daemon of `daemon_ctx`; `base_url` is the server's
  URL (the MCP endpoint of the descriptions); `tokens` the push tokens
  fetched before (`GitRepo.prefetch_push_tokens/1`). Returns the
  descriptions (none: `{:ok, []}`); `{:error, :reauthorized}` for a
  revoked daemon or another authorization epoch.
  """
  @spec claim(Lifecycle.daemon_ctx(), String.t(), GitRepo.tokens()) ::
          {:ok, [HelmsmanProtocol.RunSpec.t()]} | {:error, :reauthorized}
  def claim(ctx, base_url, tokens \\ %{}) do
    Tx.run(fn ->
      with true <- Locks.try_daemon(ctx.daemon_id),
           {:ok, daemon} <- Lifecycle.lock_daemon(ctx) do
        slots = daemon.max_concurrency - active_count(:daemon_id, daemon.id)
        protocol = Map.get(ctx, :protocol, HelmsmanProtocol.min_version())
        args = {base_url, tokens, protocol}
        claim_from(daemon, runtime_ids(daemon), slots, args)
      else
        false -> {:ok, []}
        error -> error
      end
    end)
  end

  defp claim_from(_daemon, ids, slots, _args) when slots <= 0 or ids == [], do: {:ok, []}

  defp claim_from(daemon, ids, slots, {base_url, tokens, protocol}) do
    state = %{
      daemon: daemon,
      protocol: protocol,
      base_url: base_url,
      tokens: tokens,
      slots: slots,
      seen: [],
      specs: []
    }

    {:ok, state |> scan(ids) |> Map.fetch!(:specs) |> Enum.reverse()}
  end

  defp active_count(field, id) do
    Repo.aggregate(
      from(r in Run, where: field(r, ^field) == ^id and r.status in ^Run.active_statuses()),
      :count
    )
  end

  @doc false
  # The runtimes the daemon claims from: online, enabled, in a workspace it
  # serves and where its user is a member or above.
  @spec runtime_ids(Daemon.t()) :: [pos_integer()]
  def runtime_ids(%Daemon{} = daemon) do
    Repo.all(
      from(r in Runtime,
        join: dw in DaemonWorkspace,
        on: dw.daemon_id == r.daemon_id and dw.workspace_id == r.workspace_id,
        join: m in Membership,
        on: m.workspace_id == r.workspace_id and m.user_id == ^daemon.user_id,
        where:
          r.daemon_id == ^daemon.id and is_nil(r.disabled_at) and r.status == "online" and
            m.role in ^@member_roles,
        select: r.id
      )
    )
  end

  defp scan(state, runtime_ids) do
    limit = min(@batch, @max_scan - length(state.seen))

    case candidates(runtime_ids, state.seen, limit) do
      [] ->
        state

      batch ->
        state =
          Enum.reduce(batch, %{state | seen: state.seen ++ Enum.map(batch, & &1.id)}, &consider/2)

        if state.slots > 0 and length(state.seen) < @max_scan and length(batch) == limit,
          do: scan(state, runtime_ids),
          else: state
    end
  end

  defp candidates(_runtime_ids, _seen, limit) when limit <= 0, do: []

  defp candidates(runtime_ids, seen, limit) do
    test_hook(:claim_candidates)

    Repo.all(
      from(r in Run,
        where:
          r.runtime_id in ^runtime_ids and r.status == :queued and
            r.not_before <= ^DateTime.utc_now() and r.id not in ^seen,
        order_by: [desc: r.priority, asc: r.inserted_at, asc: r.id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp consider(_run, %{slots: 0} = state), do: state

  defp consider(run, state) do
    with true <- Locks.try_maint_shared(run.workspace_id),
         true <- task_free?(run),
         {:ok, locked} <- lock_rows(run, state.daemon.user_id),
         true <- agent_free?(locked.profile),
         true <- account_supported?(locked.profile, state.protocol) do
      # Read after the task lock and the check that the task has no active
      # run: the run a trigger waits for has ended, its facts are final.
      # A design run's conversation is read without a lock
      # (`add-agent-conversation` decision 10).
      locked =
        Map.merge(locked, %{
          steers: Steering.facts(run.triggers),
          design: AgentDesigns.turn_state(run),
          autopilot: Helmsman.Autopilots.record_state(run),
          spec_requests: Helmsman.TaskSpecs.request_states(run)
        })

      decide(run, locked, state)
    else
      _skip -> state
    end
  end

  defp task_free?(%Run{task_id: nil}), do: true

  defp task_free?(%Run{task_id: task_id}),
    do:
      Locks.try_task(task_id) and
        not Repo.exists?(
          from(r in Run, where: r.task_id == ^task_id and r.status in ^Run.active_statuses())
        )

  # An archived or missing profile is judged by the check, not the limit.
  defp agent_free?(nil), do: true

  defp agent_free?(%AgentProfile{} = profile),
    do: active_count(:agent_id, profile.actor_id) < profile.max_concurrency

  defp account_supported?(nil, _protocol), do: true
  defp account_supported?(%AgentProfile{provider_account_id: nil}, _protocol), do: true

  defp account_supported?(%AgentProfile{provider_account_id: id}, protocol) do
    with true <- protocol >= HelmsmanProtocol.provider_account_version(),
         {:ok, account} <- try_lock(from(a in ProviderAccount, where: a.id == ^id), :share) do
      is_nil(account) or account.header_names == [] or
        protocol >= HelmsmanProtocol.provider_account_headers_version()
    else
      _ -> false
    end
  end

  # Decision 24, in the global order. `:skip`: a writer holds one of them.
  defp lock_rows(run, daemon_user_id) do
    with {:ok, members} <- lock_members(run, daemon_user_id),
         {:ok, agent} <- try_lock(from(a in Actor, where: a.id == ^run.agent_id), :share),
         {:ok, squads} <- SquadDispatch.lock_for_check(run, :try),
         {:ok, profile} <-
           try_lock(from(p in AgentProfile, where: p.actor_id == ^run.agent_id), :update),
         {:ok, task} <- try_task_row(run),
         {:ok, runtime} <- try_lock(from(r in Runtime, where: r.id == ^run.runtime_id), :share),
         false <- is_nil(agent) do
      {:ok,
       %{
         members: members,
         agent: agent,
         squads: squads,
         profile: profile,
         task: task,
         runtime: runtime
       }}
    else
      _skip -> :skip
    end
  end

  defp try_task_row(%Run{task_id: nil}), do: {:ok, nil}
  defp try_task_row(%Run{task_id: id}), do: try_lock(from(t in Task, where: t.id == ^id), :share)

  # A row that exists but is not returned with SKIP LOCKED is held by a
  # writer: skip. A row that does not exist is nil.
  defp try_lock(query, mode) do
    exists? = Repo.exists?(query)

    row =
      case mode do
        :share -> Repo.one(lock(query, "FOR SHARE SKIP LOCKED"))
        :update -> Repo.one(lock(query, "FOR UPDATE SKIP LOCKED"))
      end

    cond do
      row -> {:ok, row}
      exists? -> :skip
      true -> {:ok, nil}
    end
  end

  defp lock_members(run, daemon_user_id) do
    query =
      from(m in Membership,
        where:
          m.workspace_id == ^run.workspace_id and
            m.user_id in ^Lifecycle.user_ids(run, daemon_user_id)
      )

    existing = Repo.aggregate(query, :count)

    rows =
      Repo.all(
        from(m in query,
          order_by: m.id,
          lock: "FOR SHARE SKIP LOCKED",
          select: {m.user_id, m.role}
        )
      )

    if length(rows) < existing, do: :skip, else: {:ok, Map.new(rows)}
  end

  defp decide(run, locked, state) do
    if Map.get(locked.members, state.daemon.user_id) in @member_roles do
      case Runs.revalidate(run, locked) do
        :ok ->
          with_dependencies(run, locked, [], state)

        {:pruned, changes} ->
          with_dependencies(run, locked, Map.to_list(changes), state)

        {:obsolete, why} ->
          cancel!(run, :obsolete, state, Lifecycle.obsolete_error(run, why, locked))

        :unauthorized ->
          cancel!(run, :unauthorized, state, [])
      end
    else
      state
    end
  end

  defp cancel!(run, reason, state, changes) do
    Lifecycle.end!(run, :cancelled, [failure_reason: reason] ++ changes)
    state
  end

  # `add-dependency-dispatch` decision 7: a run there only for assignment
  # triggers, on a task with dependencies, checks them again under the
  # graph lock, taken without waiting (taken: the run stays queued).
  # Unsatisfied: back to `deferred`, not claimed.
  defp with_dependencies(run, locked, changes, state) do
    triggers = Keyword.get(changes, :triggers, run.triggers)

    if run.task_id && Triggers.dependency_gated?(triggers) &&
         Links.has_dependencies?(run.task_id) do
      cond do
        not Locks.try_graph(run.workspace_id) ->
          state

        Links.blockers(run.task_id) != [] ->
          test_hook(:dependencies_rechecked)
          Lifecycle.update!(run, [status: :deferred] ++ changes)
          state

        true ->
          with_repo(run, locked, changes, state)
      end
    else
      with_repo(run, locked, changes, state)
    end
  end

  defp with_repo(run, locked, changes, state) do
    case snapshot_refusal(run, locked.task, state) do
      nil -> with_local_repo(run, locked, changes, state)
      message -> fail_prepare!(run, message, state)
    end
  end

  # `add-autopilots` decision 13: a run-only autopilot run in a repository
  # needs a daemon that can check it out read-only; only that machine (a
  # local repository) or that daemon claimed it, so it would wait forever.
  defp snapshot_refusal(run, nil, state) do
    with %{} = project <- Autopilots.run_project(run),
         true <- not is_nil(project.repository_id) or not is_nil(project.local_repository_id),
         true <- state.protocol < Autopilots.snapshot_version() do
      "the daemon on #{state.daemon.name} is too old to run autopilots in a repository; " <>
        "upgrade it"
    else
      _ -> nil
    end
  end

  defp snapshot_refusal(_run, _task, _state), do: nil

  defp with_local_repo(run, locked, changes, state) do
    case LocalRepo.resolve(run, locked.task, state.daemon, state.protocol) do
      :none ->
        with_github_repo(run, locked, changes, state)

      {:ok, repo} ->
        changes =
          changes ++ [local_repository_id: repo.local_repository.id, branch: repo.branch]

        claim!(run, locked, changes, repo, state)

      {:unavailable, message} ->
        fail_prepare!(run, message, state)
    end
  end

  defp with_github_repo(run, locked, changes, state) do
    case GitRepo.resolve(run, locked.task, state.tokens) do
      :none ->
        claim!(run, locked, changes, nil, state)

      {:ok, repo} ->
        changes = changes ++ [repository_id: repo.repository.id, branch: repo.branch]
        claim!(run, locked, changes, repo, state)

      :no_token ->
        state

      {:unavailable, message} ->
        fail_prepare!(run, message, state)
    end
  end

  defp fail_prepare!(run, message, state) do
    run
    |> Lifecycle.end!(:failed, failure_reason: :workspace_prepare, error: message)
    |> Lifecycle.maybe_retry()

    state
  end

  defp claim!(run, locked, changes, repo, state) do
    run =
      Lifecycle.update!(
        run,
        [
          status: :claimed,
          daemon_id: state.daemon.id,
          claimed_at: DateTime.utc_now(),
          capabilities:
            Runs.capabilities(locked.profile, locked.task, run.triggers, run.squad_id),
          provider_account_id: locked.profile.provider_account_id
        ] ++ changes
      )

    {:ok, token} = RunTokens.issue(run)
    {:ok, spec} = Spec.build(run, token, state.base_url, repo)
    # A claimed run makes its task wait (`run`): its dependents are told
    # (`add-dependency-dispatch` decision 6). After the commit, so that
    # claiming never waits on another transaction's job insert.
    Tx.after_commit(fn -> Dependencies.changed(run.task_id) end)
    Tx.after_commit(fn -> claimed_event(run) end)
    %{state | slots: state.slots - 1, specs: [spec | state.specs]}
  end

  # The metric `helmsman.runs.claim.wait_ms`: from creation to claim. Only
  # the duration, nothing about the workspace, task or agent.
  defp claimed_event(%Run{claimed_at: claimed_at, inserted_at: inserted_at}) do
    :telemetry.execute(
      [:helmsman, :runs, :claim],
      %{wait_ms: max(DateTime.diff(claimed_at, inserted_at, :millisecond), 0)},
      %{}
    )
  end

  # Fault injection for the concurrency tests: compiled in the test
  # environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end

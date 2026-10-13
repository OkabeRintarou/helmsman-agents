defmodule Helmsman.CommittedData do
  @moduledoc """
  Helpers for `async: false` tests that commit data on their own
  connections outside the SQL sandbox.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Repo

  @doc "Runs `fun` on a connection of its own, outside the sandbox."
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Deletes, children first, the committed rows of the given users: the
  workspaces they own (including a first user's `default` workspace) with
  their runs, projects, tasks (with their pull requests and reconciliation jobs) and GitHub installations and repositories, their invitations, API tokens, memberships and identities elsewhere, their
  session tokens and the users. `extra_workspace_ids` are deleted too,
  whoever owns them (for tests whose outcome may leave a workspace without
  an owner). Every other row is left alone.
  """
  def delete_user_data!(user_ids, extra_workspace_ids \\ []) do
    unboxed(fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT workspace_id FROM memberships WHERE user_id = ANY($1) AND role = 'owner'",
          [user_ids]
        )

      workspace_ids = Enum.uniq(List.flatten(rows) ++ extra_workspace_ids)

      # Runs first: they refer to runtimes, actors and tasks.
      run_ids =
        "SELECT id FROM runs WHERE workspace_id = ANY($1) OR runtime_id IN " <>
          "(SELECT id FROM runtimes WHERE daemon_id IN " <>
          "(SELECT id FROM daemons WHERE user_id = ANY($2)))"

      for table <- ["task_events", "feedback"] do
        Repo.query!(
          "UPDATE #{table} SET source_run_id = NULL WHERE source_run_id IN (#{run_ids})",
          [workspace_ids, user_ids]
        )
      end

      # Autopilots (add-autopilots) refer to agents, projects, tasks and
      # runs; their records go with them.
      Repo.query!("DELETE FROM autopilots WHERE workspace_id = ANY($1)", [workspace_ids])

      Repo.query!(
        "DELETE FROM oban_jobs WHERE worker LIKE 'Helmsman.Autopilots.Workers.%' " <>
          "AND (args->>'autopilot_id')::bigint NOT IN (SELECT id FROM autopilots)"
      )

      # Creation conversations (add-agent-conversation) refer to runs and
      # agents; their settlement jobs to runs.
      Repo.query!(
        "DELETE FROM agent_designs WHERE workspace_id = ANY($1) OR user_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM oban_jobs WHERE worker = 'Helmsman.AgentDesigns.SettleTurn' " <>
          "AND (args->>'run_id')::bigint IN (#{run_ids})",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM oban_jobs WHERE (worker LIKE 'Helmsman.Runs.Workers.%' " <>
          "OR worker = 'Helmsman.LocalRepositories.Workers.RecordBranch') " <>
          "AND (args->>'run_id')::bigint IN (#{run_ids})",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM run_steers WHERE workspace_id = ANY($1) OR run_id IN (#{run_ids})",
        [workspace_ids, user_ids]
      )

      Repo.query!("DELETE FROM run_tokens WHERE run_id IN (#{run_ids})", [
        workspace_ids,
        user_ids
      ])

      Repo.query!("DELETE FROM task_grants WHERE workspace_id = ANY($1)", [workspace_ids])
      Repo.query!("DELETE FROM runs WHERE id IN (#{run_ids})", [workspace_ids, user_ids])

      Repo.query!(
        "DELETE FROM agent_profiles WHERE workspace_id = ANY($1) OR actor_id IN " <>
          "(SELECT id FROM actors WHERE user_id = ANY($2) OR owner_id = ANY($2)) OR runtime_id IN " <>
          "(SELECT id FROM runtimes WHERE daemon_id IN " <>
          "(SELECT id FROM daemons WHERE user_id = ANY($2)))",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM runtimes WHERE workspace_id = ANY($1) OR daemon_id IN " <>
          "(SELECT id FROM daemons WHERE user_id = ANY($2))",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM daemon_workspaces WHERE workspace_id = ANY($1) OR daemon_id IN " <>
          "(SELECT id FROM daemons WHERE user_id = ANY($2))",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM device_codes WHERE user_id = ANY($1) OR workspace_ids && $2",
        [user_ids, workspace_ids]
      )

      # Local repositories (add-local-repositories) refer to daemons and are
      # referred to by projects and task branches.
      local_repository_ids =
        "SELECT id FROM local_repositories WHERE workspace_id = ANY($1) OR daemon_id IN " <>
          "(SELECT id FROM daemons WHERE user_id = ANY($2))"

      Repo.query!(
        "DELETE FROM task_local_branches WHERE workspace_id = ANY($1) OR " <>
          "local_repository_id IN (#{local_repository_ids})",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "UPDATE projects SET local_repository_id = NULL WHERE local_repository_id IN " <>
          "(#{local_repository_ids})",
        [workspace_ids, user_ids]
      )

      Repo.query!("DELETE FROM local_repositories WHERE id IN (#{local_repository_ids})", [
        workspace_ids,
        user_ids
      ])

      Repo.query!("DELETE FROM daemons WHERE user_id = ANY($1)", [user_ids])

      # Pull request reconciliation and dependency re-check jobs of the
      # workspaces' tasks.
      Repo.query!(
        "DELETE FROM oban_jobs WHERE worker IN ('Helmsman.GitHub.Workers.ReconcilePR', " <>
          "'Helmsman.Dispatch.Workers.ReleaseDependents') " <>
          "AND (args->>'task_id')::bigint IN (SELECT id FROM tasks WHERE workspace_id = ANY($1))",
        [workspace_ids]
      )

      # Steps refer to their epics in the same table.
      Repo.query!("UPDATE tasks SET epic_id = NULL WHERE workspace_id = ANY($1)", [workspace_ids])

      for table <- [
            "task_links",
            "task_pull_requests",
            "task_events",
            "feedback",
            "tasks",
            "projects",
            "repositories",
            "github_installations"
          ] do
        Repo.query!("DELETE FROM #{table} WHERE workspace_id = ANY($1)", [workspace_ids])
      end

      Repo.query!(
        "DELETE FROM invitations WHERE workspace_id = ANY($1) OR invited_by_id = ANY($2) " <>
          "OR accepted_by_id = ANY($2) OR revoked_by_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM api_tokens WHERE workspace_id = ANY($1) OR user_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      # Squads (add-squads) refer to actors; runs and grants were deleted.
      for table <- ["squad_members", "squads"] do
        Repo.query!("DELETE FROM #{table} WHERE workspace_id = ANY($1)", [workspace_ids])
      end

      Repo.query!(
        "DELETE FROM actors WHERE workspace_id = ANY($1) OR user_id = ANY($2) OR owner_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM memberships WHERE workspace_id = ANY($1) OR user_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!("DELETE FROM workspaces WHERE id = ANY($1)", [workspace_ids])
      Repo.query!("DELETE FROM users_tokens WHERE user_id = ANY($1)", [user_ids])
      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [user_ids])
    end)

    :ok
  end

  @doc "Returns the backend pid of the caller's current connection."
  def backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  @doc "Returns true if the database backend `pid` is waiting for a lock."
  def lock_waiting?(pid) do
    %{rows: rows} =
      unboxed(fn ->
        Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    rows == [["Lock"]]
  end

  @doc """
  Waits until the database backend `pid` is blocked waiting for a lock;
  raises after `timeout` milliseconds.
  """
  def await_lock_wait(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_lock_wait(pid, deadline)
  end

  defp poll_lock_wait(pid, deadline) do
    cond do
      lock_waiting?(pid) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "backend #{pid} is not waiting for a lock"

      true ->
        Process.sleep(10)
        poll_lock_wait(pid, deadline)
    end
  end
end

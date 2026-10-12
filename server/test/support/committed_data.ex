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
  their projects, tasks and GitHub installations and repositories, their invitations, API tokens, memberships and identities elsewhere, their
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

      for table <- [
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

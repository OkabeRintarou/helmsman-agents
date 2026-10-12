defmodule Helmsman.Runs.RunTokens do
  @moduledoc """
  The `hmr_` tokens of runs (designs/12 §4, 13 §2.3, decision 9).

  A token is `hmr_` and 32 random bytes in base32; only its SHA-256 is
  stored. It is issued when the run is claimed (`add-run-lifecycle`),
  valid for 24 hours while the run is `claimed`, `running` or
  `cancelling`, and only while the agent's owner is a member of the
  workspace. The plaintext is only ever the return value of `issue/2`.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.RateLimit
  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, RunToken}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.{Membership, Workspace}

  @prefix "hmr_"
  @random_bytes 32
  @token_length byte_size(@prefix) + 52
  @ttl_seconds 24 * 3600
  @rate_window_ms 60_000
  @default_rate_limit 600

  @type found :: %{
          run: Run.t(),
          agent: Actor.t(),
          user: User.t(),
          workspace: Workspace.t(),
          role: Membership.role()
        }

  @doc """
  Issues the token of `run` (one per run). Options: `:now`.
  """
  @spec issue(Run.t(), keyword()) :: {:ok, String.t()}
  def issue(%Run{id: run_id}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    token =
      @prefix <>
        Base.encode32(:crypto.strong_rand_bytes(@random_bytes), case: :lower, padding: false)

    Repo.insert!(%RunToken{
      run_id: run_id,
      token_hash: hash(token),
      expires_at: DateTime.add(now, @ttl_seconds, :second),
      inserted_at: now
    })

    {:ok, token}
  end

  @doc """
  Checks a run token: known, not revoked, not expired, its run `claimed`,
  `running` or `cancelling`, and the agent's owner still a member (`role`
  is their current role). A disabled agent is not refused here (writes
  are, by `Helmsman.Actors.with_writer/3`). The run comes with its task
  loaded (nil without one). Options: `:now`.
  """
  @spec authenticate(String.t(), keyword()) :: {:ok, found()} | {:error, :unauthorized}
  def authenticate(token, opts \\ [])

  def authenticate(@prefix <> _ = token, opts) when byte_size(token) == @token_length do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    query =
      from(t in RunToken,
        join: r in Run,
        on: r.id == t.run_id,
        join: a in Actor,
        on: a.id == r.agent_id,
        join: u in User,
        on: u.id == a.owner_id,
        join: m in Membership,
        on: m.workspace_id == r.workspace_id and m.user_id == u.id,
        join: w in Workspace,
        on: w.id == r.workspace_id,
        left_join: task in Task,
        on: task.id == r.task_id,
        where: t.token_hash == ^hash(token) and is_nil(t.revoked_at) and t.expires_at > ^now,
        where: r.status in ^Run.active_statuses(),
        select: {%{run: r, agent: a, user: u, workspace: w, role: m.role}, task}
      )

    case Repo.one(query) do
      nil -> {:error, :unauthorized}
      {found, task} -> {:ok, %{found | run: %{found.run | task: task}}}
    end
  end

  def authenticate(_token, _opts), do: {:error, :unauthorized}

  @doc """
  The scope of a run token (`via: :run`): the agent's owner and current
  role, the agent as the actor, the run. `{:error, :unauthorized}` as
  `authenticate/2`.
  """
  @spec scope(String.t(), keyword()) :: {:ok, Scope.t()} | {:error, :unauthorized}
  def scope(token, opts \\ []) do
    with {:ok, found} <- authenticate(token, opts) do
      {:ok,
       %Scope{
         user: found.user,
         workspace: found.workspace,
         role: found.role,
         actor: found.agent,
         via: :run,
         run: found.run,
         token: nil
       }}
    end
  end

  @doc """
  Counts one request of `run`'s token against its rate limit: the budget
  of API tokens (`config :helmsman, :api_token_rate_limit` per minute,
  default #{@default_rate_limit}), keyed by the run.
  """
  @spec check_rate_limit(Run.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check_rate_limit(%Run{id: id}) do
    limit = Application.get_env(:helmsman, :api_token_rate_limit, @default_rate_limit)

    case RateLimit.hit({:run_token, id}, @rate_window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, max(1, ceil(retry_after_ms / 1000))}}
    end
  end

  @doc """
  Checks again, inside a write transaction of a run scope, that its run is
  still `claimed`, `running` or `cancelling` and its token neither revoked
  nor expired; `:ok` for any other scope.

  Call it after the write's other locks (runs come last, designs/01 §4):
  the run and token rows are locked `FOR SHARE` until the commit, so a run
  that ends (run row `FOR UPDATE`) or a token that is revoked waits for
  the write, or the write sees it and gets `{:error, :run_ended}`, which
  rolls it back. Status, revocation and expiry are judged once the lock is
  held, with the clock read then. The authentication of the request is not enough: the
  write may have waited on a lock while the run ended.
  """
  @spec lock_active(Scope.t()) :: :ok | {:error, :run_ended}
  def lock_active(%Scope{via: :run, run: %Run{id: run_id}}) do
    query =
      from(t in RunToken,
        join: r in Run,
        on: r.id == t.run_id,
        where: r.id == ^run_id,
        lock: "FOR SHARE",
        select: {r.status, t.revoked_at, t.expires_at}
      )

    # Judged after the lock is held, on the rows as committed then and with
    # the time then: the wait may outlast the token's expiry.
    case Repo.one(query) do
      {status, nil, expires_at} ->
        if status in Run.active_statuses() and
             DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
           do: :ok,
           else: {:error, :run_ended}

      _revoked_or_missing ->
        {:error, :run_ended}
    end
  end

  def lock_active(%Scope{}), do: :ok

  @doc "Revokes the token of the run `run_id`, if any."
  @spec revoke(pos_integer()) :: :ok
  def revoke(run_id) when is_integer(run_id) do
    Repo.update_all(
      from(t in RunToken, where: t.run_id == ^run_id and is_nil(t.revoked_at)),
      set: [revoked_at: DateTime.utc_now()]
    )

    :ok
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end

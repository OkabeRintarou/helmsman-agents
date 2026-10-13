defmodule Helmsman.Actors do
  @moduledoc """
  Actors: every identity that appears in records (humans, agents, squads and
  the workspace's system identity `helmsman`).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.RunTokens
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  defdelegate request_claim(scope, name), to: Helmsman.Actors.Claims, as: :request
  defdelegate list_claims(scope), to: Helmsman.Actors.Claims, as: :list
  defdelegate decide_claim(scope, id, decision), to: Helmsman.Actors.Claims, as: :decide
  defdelegate cancel_claim(scope, id), to: Helmsman.Actors.Claims, as: :cancel
  defdelegate claim_for(scope, name, user_id), to: Helmsman.Actors.Claims
  defdelegate transfer_agent(scope, name, user_id), to: Helmsman.Actors.Claims, as: :transfer

  @base_max 60
  @name_max 64
  @max_attempts 10

  @doc """
  Derives the base name of a human identity from an email address.

  Takes the part before `@`, downcases it, replaces characters outside
  `[a-z0-9._-]` with `-`, drops leading non-alphanumeric characters and
  truncates to #{@base_max} characters; an empty result becomes `user`.

      iex> derive_human_name("Alice.W@example.com")
      "alice.w"

      iex> derive_human_name("+ops+bob@example.com")
      "ops-bob"
  """
  @spec derive_human_name(String.t()) :: String.t()
  def derive_human_name(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> hd()
    |> String.downcase()
    |> then(&Regex.replace(~r/[^a-z0-9._-]/u, &1, "-"))
    |> String.replace(~r/^[^a-z0-9]+/, "")
    |> String.slice(0, @base_max)
    |> case do
      "" -> "user"
      name -> name
    end
  end

  @doc """
  Returns the user's human identity in `workspace`, creating it if needed.

  Runs in the caller's transaction. The name is derived with
  `derive_human_name/1`; on a conflict `-2`, `-3`, ... is appended. The
  insert uses `ON CONFLICT DO NOTHING`, so a concurrent insert of the same
  name or of the same user's identity never aborts the caller's
  transaction.
  """
  @spec ensure_human(Workspace.t(), User.t()) ::
          {:ok, Actor.t()} | {:error, :name_unavailable}
  def ensure_human(%Workspace{} = workspace, %User{} = user) do
    case get_human(workspace.id, user.id) do
      %Actor{} = actor -> {:ok, actor}
      nil -> insert_human(workspace, user, derive_human_name(user.email), @max_attempts)
    end
  end

  defp insert_human(_workspace, _user, _base, 0), do: {:error, :name_unavailable}

  defp insert_human(workspace, user, base, attempts) do
    name = next_free_name(workspace.id, base)

    row = %{
      workspace_id: workspace.id,
      kind: :human,
      name: name,
      user_id: user.id
    }

    case insert_ignoring_conflicts(row) do
      {:ok, actor} ->
        {:ok, actor}

      :conflict ->
        # Either the same user joined concurrently or the name was taken.
        case get_human(workspace.id, user.id) do
          %Actor{} = actor -> {:ok, actor}
          nil -> insert_human(workspace, user, base, attempts - 1)
        end
    end
  end

  # Picks `base`, else the lowest free `base-N` (N >= 2). `helmsman` counts
  # as taken.
  defp next_free_name(workspace_id, base) do
    pattern = escape_like(base) <> "-%"

    taken =
      from(a in Actor,
        where: a.workspace_id == ^workspace_id,
        where: a.name == ^base or like(a.name, ^pattern),
        select: fragment("lower(?::text)", a.name)
      )
      |> Repo.all()
      |> MapSet.new()
      |> MapSet.put(Actor.system_name())

    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&with_suffix(base, &1))
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  defp with_suffix(base, n) do
    suffix = "-#{n}"
    String.slice(base, 0, @name_max - String.length(suffix)) <> suffix
  end

  defp escape_like(string), do: String.replace(string, ~r/([\\%_])/, "\\\\\\1")

  @doc """
  Returns the workspace's system identity `helmsman`, creating it if needed.

  Runs in the caller's transaction.
  """
  @spec ensure_system(Workspace.t()) :: {:ok, Actor.t()}
  def ensure_system(%Workspace{} = workspace) do
    row = %{workspace_id: workspace.id, kind: :system, name: Actor.system_name()}

    case insert_ignoring_conflicts(row) do
      {:ok, actor} ->
        {:ok, actor}

      :conflict ->
        {:ok,
         Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace.id and a.kind == :system))}
    end
  end

  defp insert_ignoring_conflicts(row) do
    now = DateTime.utc_now(:second)
    row = Map.merge(row, %{inserted_at: now, updated_at: now})

    case Repo.insert_all(Actor, [row], on_conflict: :nothing, returning: true) do
      {1, [actor]} -> {:ok, actor}
      {0, []} -> :conflict
    end
  end

  @doc "Returns the user's human identity in the workspace, or nil."
  @spec get_human(pos_integer(), pos_integer()) :: Actor.t() | nil
  def get_human(workspace_id, user_id) do
    Repo.one(
      from(a in Actor,
        where: a.workspace_id == ^workspace_id and a.user_id == ^user_id and a.kind == :human
      )
    )
  end

  @doc """
  Lists the identities a task may be assigned to (`:read_tasks`): the
  workspace's humans, agents and squads (`add-squads` decision 4) that are
  not disabled, as `Helmsman.Tasks.update/4` accepts them. Humans first,
  then agents, then squads, each by name; agents have their `owner`
  preloaded.
  """
  @spec list_assignable(Scope.t()) :: {:ok, [Actor.t()]} | {:error, :forbidden}
  def list_assignable(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :read_tasks) do
      actors =
        from(a in Actor,
          where:
            a.workspace_id == ^workspace_id and a.kind in [:human, :agent, :squad] and
              is_nil(a.disabled_at) and (a.kind != :human or not is_nil(a.user_id)),
          order_by: [
            asc: fragment("CASE ? WHEN 'human' THEN 0 WHEN 'agent' THEN 1 ELSE 2 END", a.kind),
            asc: a.name
          ],
          preload: :owner
        )
        |> Repo.all()

      {:ok, actors}
    end
  end

  @doc """
  Lists the scope user's own enabled agents in the workspace, by name: the
  agents a new API token may default to (see `Helmsman.ApiTokens`). Every
  role may list them; scopes that may not list their own tokens (no role,
  agent identities) get `[]`.
  """
  @spec list_own_agents(Scope.t()) :: [Actor.t()]
  def list_own_agents(
        %Scope{workspace: %Workspace{id: workspace_id}, user: %User{id: user_id}} = scope
      ) do
    case Policy.authorize(scope, :list_own_tokens) do
      :ok ->
        from(a in Actor,
          where:
            a.workspace_id == ^workspace_id and a.kind == :agent and a.owner_id == ^user_id and
              is_nil(a.disabled_at),
          order_by: [asc: a.name]
        )
        |> Repo.all()

      {:error, :forbidden} ->
        []
    end
  end

  @doc """
  Renames the human identity the scope acts as.
  """
  @spec rename_own(Scope.t(), String.t()) ::
          {:ok, Actor.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def rename_own(%Scope{actor: %Actor{} = actor} = scope, new_name) do
    rename(scope, actor, new_name)
  end

  @doc """
  Renames `actor`. Only allowed for the caller's own human identity
  (`:rename_own_actor`); system identities can never be renamed.
  """
  @spec rename(Scope.t(), Actor.t(), String.t()) ::
          {:ok, Actor.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def rename(%Scope{} = scope, %Actor{} = actor, new_name) do
    Workspaces.write_transaction(scope, :rename_own_actor, actor, fn scope ->
      query =
        from(a in Actor,
          where: a.workspace_id == ^scope.workspace.id and a.id == ^actor.id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        current -> current |> Actor.rename_changeset(%{name: new_name}) |> Repo.update()
      end
    end)
  end

  ## External agents

  @type identify_error ::
          :forbidden | :not_found | :name_taken | :agent_disabled | Ecto.Changeset.t() | atom()

  @doc """
  Creates or reuses the agent identity `name` for the scope's user
  (designs/03 §4), as a workspace write (`:identify`, member and above;
  agents too).

  `attrs`: `:name`, optional `:project` (project key) and `:worktree`.

    * no actor has the name: an agent owned by the user is created;
    * an active agent of the user's: it is reused; `project_key` and
      `worktree` are updated when given and `last_seen_at` always;
    * an agent of the user's that is disabled: `{:error, :agent_disabled}`;
    * any other actor (a human, including the user's own, someone else's
      agent, a squad, the system identity): `{:error, :name_taken}`.

  A name that breaks the actor naming rule returns `{:error, changeset}`,
  whether or not an actor with a case-insensitively equal name exists.
  """
  @spec identify(Scope.t(), map()) :: {:ok, Actor.t()} | {:error, identify_error()}
  def identify(%Scope{} = scope, attrs) when is_map(attrs) do
    name = Map.get(attrs, :name)
    meta = %{project_key: Map.get(attrs, :project), worktree: Map.get(attrs, :worktree)}

    Workspaces.write_transaction(scope, :identify, nil, fn scope ->
      # Checked before the lookup: names are citext, so an invalid variant
      # such as `Keel/Dev` would otherwise match and reuse `keel/dev`.
      with :ok <- validate_agent_name(scope, name) do
        identify_locked(scope, name, meta)
      end
    end)
  end

  defp identify_locked(scope, name, meta) do
    case actor_by_name(scope.workspace.id, name, :update) do
      nil -> insert_agent(scope, name, meta)
      actor -> reuse_agent(scope, actor, meta)
    end
  end

  defp validate_agent_name(scope, name) do
    if is_binary(name) and Actor.valid_name?(name) do
      :ok
    else
      changeset = new_agent_changeset(scope, name)
      {:error, %{changeset | action: :insert}}
    end
  end

  defp new_agent_changeset(scope, name) do
    %Actor{workspace_id: scope.workspace.id, kind: :agent, owner_id: scope.user.id}
    |> Actor.create_changeset(%{name: name})
  end

  defp insert_agent(scope, name, meta) do
    changeset = new_agent_changeset(scope, name)

    row = %{
      workspace_id: scope.workspace.id,
      kind: :agent,
      name: name,
      owner_id: scope.user.id,
      project_key: meta.project_key,
      worktree: meta.worktree,
      last_seen_at: DateTime.utc_now()
    }

    with %Ecto.Changeset{valid?: true} <- changeset,
         :conflict <- insert_ignoring_conflicts(row) do
      # Someone created the name concurrently; judge what they created.
      case actor_by_name(scope.workspace.id, name, :update) do
        nil -> {:error, :name_taken}
        actor -> reuse_agent(scope, actor, meta)
      end
    else
      %Ecto.Changeset{} = changeset -> {:error, %{changeset | action: :insert}}
      {:ok, actor} -> {:ok, actor}
    end
  end

  defp reuse_agent(%Scope{user: %User{id: user_id}}, actor, meta) do
    case actor do
      %Actor{kind: :agent, owner_id: ^user_id, disabled_at: nil} ->
        changes =
          meta
          |> Enum.reject(fn {_field, value} -> is_nil(value) end)
          |> Map.new()
          |> Map.put(:last_seen_at, DateTime.utc_now())

        actor |> Ecto.Changeset.change(changes) |> Repo.update()

      %Actor{kind: :agent, owner_id: ^user_id} ->
        {:error, :agent_disabled}

      _other ->
        {:error, :name_taken}
    end
  end

  defp actor_by_name(workspace_id, name, :update) when is_binary(name),
    do: workspace_id |> name_query(name) |> lock("FOR UPDATE") |> Repo.one()

  defp actor_by_name(workspace_id, name, :share) when is_binary(name),
    do: workspace_id |> name_query(name) |> lock("FOR SHARE") |> Repo.one()

  defp actor_by_name(_workspace_id, _name, _lock), do: nil

  defp name_query(workspace_id, name),
    do: from(a in Actor, where: a.workspace_id == ^workspace_id and a.name == ^name)

  @type resolve_error ::
          :forbidden | {:agent_disabled, String.t()} | :needs_session_agent | :not_found

  @doc """
  Resolves the actor a write over MCP or REST is recorded as
  (designs/03 §4), in order:

    1. `opts[:requested]`, the name given by the request (MCP `actor` /
       `author`, REST `X-Helmsman-Actor`);
    2. `opts[:session_actor_id]`, the MCP session identity set by
       `identify/2`;
    3. the token's default agent;
    4. REST: the user's human identity; MCP: `{:error, :needs_session_agent}`
       (the MCP endpoint then creates the session's own agent).

  Steps 1-3 only accept an agent the token's user owns: anything else is
  `{:error, :forbidden}`, and a disabled one `{:error, {:agent_disabled,
  name}}`. Call it inside the write's transaction: the actor row is locked
  `FOR SHARE`.
  """
  @spec resolve_writer(Scope.t(), keyword()) :: {:ok, Actor.t()} | {:error, resolve_error()}
  def resolve_writer(%Scope{via: via} = scope, opts) when via in [:api, :mcp] do
    with {:ok, actor, _source} <- resolve_writer_source(scope, opts), do: {:ok, actor}
  end

  defp resolve_writer_source(%Scope{via: via} = scope, opts) do
    workspace_id = scope.workspace.id

    cond do
      name = opts[:requested] ->
        own_agent(scope, actor_by_name(workspace_id, name, :share), :requested)

      id = opts[:session_actor_id] ->
        own_agent(scope, actor_by_id(workspace_id, id), :session)

      match?(%ApiToken{default_agent_id: id} when not is_nil(id), scope.token) ->
        own_agent(scope, actor_by_id(workspace_id, scope.token.default_agent_id), :default)

      via == :api ->
        case get_human(workspace_id, scope.user.id) do
          nil -> {:error, :not_found}
          human -> {:ok, human, :human}
        end

      via == :mcp ->
        {:error, :needs_session_agent}
    end
  end

  @type reader_source :: :requested | :default | :human

  @doc """
  Resolves the current identity of a REST read (`add-rest-api` decision
  3), in the order of `resolve_writer/2`: `requested` (the request's
  `X-Helmsman-Actor`), the token's default agent, then the user's human
  identity. A requested name or default agent must be an agent the
  token's user owns, else `{:error, :forbidden}`; unlike writes, a
  disabled one is accepted (a disabled identity can still read).

  Reads without locks, so it may run outside a transaction. Returns the
  actor and where it came from.
  """
  @spec resolve_reader(Scope.t(), String.t() | nil) ::
          {:ok, Actor.t(), reader_source()} | {:error, :forbidden | :not_found}
  def resolve_reader(%Scope{via: :api, workspace: workspace, user: user} = scope, requested)
      when is_binary(requested) or is_nil(requested) do
    cond do
      is_binary(requested) ->
        workspace.id |> name_query(requested) |> Repo.one() |> own_reader(user, :requested)

      match?(%ApiToken{default_agent_id: id} when not is_nil(id), scope.token) ->
        workspace.id |> get(scope.token.default_agent_id) |> own_reader(user, :default)

      true ->
        case get_human(workspace.id, user.id) do
          nil -> {:error, :not_found}
          human -> {:ok, human, :human}
        end
    end
  end

  defp own_reader(%Actor{kind: :agent, owner_id: owner_id} = actor, %User{id: owner_id}, source),
    do: {:ok, actor, source}

  defp own_reader(_actor, _user, _source), do: {:error, :forbidden}

  defp own_agent(%Scope{user: %User{id: user_id}}, actor, source) do
    case actor do
      %Actor{kind: :agent, owner_id: ^user_id, disabled_at: nil} -> {:ok, actor, source}
      %Actor{kind: :agent, owner_id: ^user_id, name: name} -> {:error, {:agent_disabled, name}}
      _other -> {:error, :forbidden}
    end
  end

  defp actor_by_id(workspace_id, id) do
    Repo.one(
      from(a in Actor, where: a.workspace_id == ^workspace_id and a.id == ^id, lock: "FOR SHARE")
    )
  end

  @type writer_source :: :requested | :session | :default | :auto | :human | :run

  @doc """
  Runs the write `fun` as the actor the request is recorded as
  (designs/03 §4), resolved in the same transaction.

  In one `Helmsman.Tx.run/2` (retried once on a deadlock): the maintenance
  lock (shared), the requester's membership row `FOR SHARE` (gone →
  `{:error, :not_found}`; otherwise the scope gets the current role), the
  writer as `resolve_writer/2` resolves it with `opts`, and then
  `fun.(scope)` with that actor in `scope.actor`. When the result is
  `:needs_session_agent` and `opts[:auto_agent]` is true, the session's
  own agent `<human name>/session-<6 characters>` is created first (the
  role must allow `:identify`, so viewers get `{:error, :forbidden}`).

  `fun` returns `{:ok, value}` or `{:error, reason}`; an error rolls back
  everything, the session agent included. Any other result raises
  `ArgumentError`. Domain writes inside `fun` join the transaction.

  Returns `{:ok, value, %{actor: actor, source: source}}`, `source` being
  `:requested`, `:session`, `:default`, `:auto` or, for REST, `:human`.

  A run scope (`via: :run`) always writes as its agent, `scope.actor`
  (source `:run`): `opts` are ignored, no session agent is ever created,
  and the agent's row is read again `FOR SHARE`; disabled →
  `{:error, {:agent_disabled, name}}`; after `fun` the run is checked
  again (`Helmsman.Runs.RunTokens.lock_active/1`): ended →
  `{:error, :run_ended}`, everything rolled back.
  """
  @spec with_writer(Scope.t(), keyword(), (Scope.t() -> Tx.result())) ::
          {:ok, term(), %{actor: Actor.t(), source: writer_source()}} | {:error, term()}
  def with_writer(%Scope{via: via} = scope, opts, fun)
      when via in [:api, :mcp, :run] and is_list(opts) and is_function(fun, 1) do
    case Tx.run(fn -> with_writer_locked(scope, opts, fun) end, retry: 1) do
      {:ok, %{value: value, actor: actor, source: source}} ->
        {:ok, value, %{actor: actor, source: source}}

      {:error, _reason} = error ->
        error
    end
  end

  defp with_writer_locked(%Scope{workspace: workspace, user: user} = scope, opts, fun) do
    Locks.maint_shared!(workspace.id)

    membership =
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^workspace.id and m.user_id == ^user.id,
          lock: "FOR SHARE"
        )
      )

    with %Membership{role: role} <- membership || {:error, :not_found},
         scope = %{scope | role: role},
         {:ok, actor, source} <- writer(scope, opts) do
      case fun.(%{scope | actor: actor}) do
        {:ok, value} -> finish_write(scope, %{value: value, actor: actor, source: source})
        {:error, _reason} = error -> error
        other -> raise ArgumentError, bad_write_result(other)
      end
    end
  end

  # The run is checked again last, after every lock of the write.
  defp finish_write(scope, written) do
    with :ok <- RunTokens.lock_active(scope), do: {:ok, written}
  end

  defp bad_write_result(other),
    do:
      "with_writer/3 expects the write to return {:ok, value} or " <>
        "{:error, reason}, got: #{inspect(other)}"

  defp writer(%Scope{via: :run, actor: %Actor{id: id}} = scope, _opts) do
    case actor_by_id(scope.workspace.id, id) do
      %Actor{kind: :agent, disabled_at: nil} = actor -> {:ok, actor, :run}
      %Actor{name: name} -> {:error, {:agent_disabled, name}}
      nil -> {:error, :not_found}
    end
  end

  defp writer(scope, opts) do
    case resolve_writer_source(scope, opts) do
      {:error, :needs_session_agent} = error ->
        if opts[:auto_agent], do: auto_writer(scope), else: error

      result ->
        result
    end
  end

  defp auto_writer(scope) do
    with :ok <- Policy.authorize(scope, :identify),
         {:ok, actor} <- create_session_agent(scope),
         do: {:ok, actor, :auto}
  end

  @session_prefix_max 49
  @session_attempts 3
  @suffix_alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  # The session's own agent: the user's human name (cut to 49 characters,
  # so the name stays within 64) and a random suffix; a taken name is
  # retried with another suffix.
  defp create_session_agent(%Scope{workspace: workspace, user: user}) do
    case get_human(workspace.id, user.id) do
      nil ->
        {:error, :not_found}

      human ->
        prefix = String.slice(human.name, 0, @session_prefix_max)
        insert_session_agent(workspace.id, user.id, prefix, @session_attempts)
    end
  end

  defp insert_session_agent(_workspace_id, _user_id, _prefix, 0), do: {:error, :name_taken}

  defp insert_session_agent(workspace_id, user_id, prefix, attempts) do
    row = %{
      workspace_id: workspace_id,
      kind: :agent,
      name: prefix <> "/session-" <> session_suffix(),
      owner_id: user_id,
      last_seen_at: DateTime.utc_now()
    }

    case insert_ignoring_conflicts(row) do
      {:ok, actor} -> {:ok, actor}
      :conflict -> insert_session_agent(workspace_id, user_id, prefix, attempts - 1)
    end
  end

  defp random_suffix do
    for <<byte <- :crypto.strong_rand_bytes(6)>>, into: "" do
      <<Enum.at(@suffix_alphabet, rem(byte, length(@suffix_alphabet)))>>
    end
  end

  # Tests fix the suffixes with `Process.put(:helmsman_session_agent_suffixes,
  # [...])`: compiled in the test environment only.
  if Mix.env() == :test do
    defp session_suffix do
      case Process.get(:helmsman_session_agent_suffixes) do
        [suffix | rest] ->
          Process.put(:helmsman_session_agent_suffixes, rest)
          suffix

        _none ->
          random_suffix()
      end
    end
  else
    defp session_suffix, do: random_suffix()
  end

  @doc """
  Returns the actor `id` of the workspace, without locking it, or nil.
  """
  @spec get(pos_integer(), pos_integer()) :: Actor.t() | nil
  def get(workspace_id, id) when is_integer(workspace_id) and is_integer(id) do
    case Repo.one(from(a in Actor, where: a.workspace_id == ^workspace_id and a.id == ^id)) do
      %Actor{} = actor -> %{actor | unclaimed: actor.kind == :human and is_nil(actor.user_id)}
      nil -> nil
    end
  end

  @type listed :: %{
          name: String.t(),
          kind: Actor.kind(),
          owner: String.t() | nil,
          disabled: boolean(),
          unclaimed: boolean(),
          project: String.t() | nil,
          worktree: String.t() | nil,
          last_seen_at: DateTime.t() | nil
        }

  @doc """
  Lists every identity of the workspace (`:view_members`, every role) in
  one query: humans, agents, squads, then the system identity, each by
  name. `owner` is the human name of an agent's owner in the workspace.
  """
  @spec list(Scope.t()) :: {:ok, [listed()]} | {:error, :forbidden}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :view_members) do
      actors =
        from(a in Actor,
          left_join: h in Actor,
          on: h.workspace_id == a.workspace_id and h.user_id == a.owner_id and h.kind == :human,
          where: a.workspace_id == ^workspace_id,
          order_by: [
            asc:
              fragment(
                "CASE ? WHEN 'human' THEN 0 WHEN 'agent' THEN 1 WHEN 'squad' THEN 2 ELSE 3 END",
                a.kind
              ),
            asc: a.name
          ],
          select: %{
            name: a.name,
            kind: a.kind,
            owner: h.name,
            disabled: not is_nil(a.disabled_at),
            unclaimed: a.kind == :human and is_nil(a.user_id),
            project: a.project_key,
            worktree: a.worktree,
            last_seen_at: a.last_seen_at
          }
        )
        |> Repo.all()

      {:ok, actors}
    end
  end
end

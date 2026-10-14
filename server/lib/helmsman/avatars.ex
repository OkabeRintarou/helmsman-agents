defmodule Helmsman.Avatars do
  @moduledoc """
  Avatars (`add-actor-avatars`): a user's own (shown on their human
  identity in every workspace) and those of agents and squads.

  Files are checked by `Helmsman.Avatars.Image` (decision 4) and stored in
  the database (decision 3). A write locks its target (the user row, or
  the identity row `FOR UPDATE` and a squad's row `FOR SHARE`), authorizes
  against the current state with `Helmsman.Policy` (`:set_avatar`,
  `:remove_avatar`, decision 12), replaces or deletes the avatar and, once
  committed, broadcasts `{:avatars_changed}` on the workspace topics
  concerned and, for a user's avatar, `{:user_avatar_changed}` on the
  user's topic (decision 6).
  """

  import Ecto.Query

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Avatars.{Avatar, Image}
  alias Helmsman.{Config, Events, Policy, Repo, Tx, Workspaces}
  alias Helmsman.Squads.Squad

  @typedoc "The scope user's own avatar, or the agent or squad of that name."
  @type target :: :me | {:actor, String.t()}
  @type put_error :: Image.error() | :forbidden | :not_found
  @type fetched :: %{data: binary(), content_type: String.t(), key: String.t()}

  @replaced [:content_type, :data, :key, :byte_size, :edge, :updated_by_id, :updated_at]

  @doc """
  Sets the avatar of `target` to `data`, replacing the current one. An
  invalid file returns its `Helmsman.Avatars.Image` error and changes
  nothing; so does a refusal (`:forbidden`: an agent or run scope, a
  human or system identity, or not allowed by decision 12) or an unknown
  name (`:not_found`).
  """
  @spec put(Scope.t(), target(), binary()) ::
          {:ok, %{key: String.t(), content_type: String.t()}} | {:error, put_error()}
  def put(%Scope{} = scope, target, data) when is_binary(data) do
    with {:ok, image} <- Image.validate(data) do
      write(scope, :set_avatar, target, &upsert(&1, &2, data, image))
    end
  end

  @doc """
  Removes the avatar of `target`; removing one that does not exist
  succeeds.
  """
  @spec delete(Scope.t(), target()) :: :ok | {:error, :forbidden | :not_found}
  def delete(%Scope{} = scope, target) do
    with {:ok, :ok} <- write(scope, :remove_avatar, target, &remove/2), do: :ok
  end

  @doc """
  What `scope` may do with the avatar of `target` now: `:set` (set and
  remove), `:remove_only` (an admin on someone else's agent) or `false`.
  Reads without locks; the write checks again.
  """
  @spec can_manage?(Scope.t() | nil, target()) :: :set | :remove_only | false
  def can_manage?(%Scope{user: %User{} = user} = scope, :me) do
    if Policy.authorize(scope, :set_avatar, user) == :ok, do: :set, else: false
  end

  def can_manage?(%Scope{workspace: %{id: ws}} = scope, {:actor, name}) when is_binary(name) do
    case resource(ws, name, false) do
      {:ok, resource, _actor} ->
        cond do
          Policy.authorize(scope, :set_avatar, resource) == :ok -> :set
          Policy.authorize(scope, :remove_avatar, resource) == :ok -> :remove_only
          true -> false
        end

      {:error, _reason} ->
        false
    end
  end

  def can_manage?(_scope, _target), do: false

  @doc """
  The avatar `key` as the workspace's members may read it (decision 5):
  an agent's or squad's of the workspace, or the avatar of a user who has
  a claimed human identity there. A key that is not 32 lower-case hex
  digits is `:error` without a query.
  """
  @spec fetch_for_workspace(pos_integer(), term()) :: {:ok, fetched()} | :error
  def fetch_for_workspace(workspace_id, key) when is_integer(workspace_id) do
    if Avatar.valid_key?(key) do
      humans =
        from(h in Actor,
          where: h.workspace_id == ^workspace_id and h.kind == :human and not is_nil(h.user_id),
          select: h.user_id
        )

      from(a in Avatar,
        where:
          a.key == ^key and
            (a.workspace_id == ^workspace_id or
               (not is_nil(a.user_id) and a.user_id in subquery(humans)))
      )
      |> fetch()
    else
      :error
    end
  end

  @doc "The user's own avatar `key`; `:error` for anything else."
  @spec fetch_own(pos_integer(), term()) :: {:ok, fetched()} | :error
  def fetch_own(user_id, key) when is_integer(user_id) do
    if Avatar.valid_key?(key),
      do: fetch(from(a in Avatar, where: a.user_id == ^user_id and a.key == ^key)),
      else: :error
  end

  defp fetch(query) do
    query
    |> limit(1)
    |> select([a], %{data: a.data, content_type: a.content_type, key: a.key})
    |> Repo.one()
    |> case do
      nil -> :error
      avatar -> {:ok, avatar}
    end
  end

  @doc "The read key of the user's avatar, or nil."
  @spec user_avatar_key(pos_integer()) :: String.t() | nil
  def user_avatar_key(user_id) when is_integer(user_id),
    do: Repo.one(from(a in Avatar, where: a.user_id == ^user_id, select: a.key))

  @doc """
  The absolute address of the REST read route of avatar `key` for MCP and
  REST views (decision 13): only for an API token's scope
  (`via` `:mcp` or `:api`); nil for every other scope (a run token
  included) and for no avatar.
  """
  @spec api_url(Scope.t(), String.t() | nil) :: String.t() | nil
  def api_url(%Scope{via: via, workspace: %{slug: slug}}, key)
      when via in [:mcp, :api] and is_binary(key),
      do: "#{Config.public_url()}/api/v1/w/#{slug}/avatars/#{key}"

  def api_url(_scope, _key), do: nil

  ## Writes

  defp write(%Scope{user: %User{id: user_id}} = scope, action, :me, fun) do
    Tx.run(
      fn ->
        user = Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

        with %User{} <- user || {:error, :not_found},
             :ok <- Policy.authorize(scope, action, user),
             {:ok, _value} = result <- fun.({:user, user}, scope) do
          result
        end
      end,
      retry: 1
    )
  end

  defp write(%Scope{workspace: %{id: _}} = scope, action, {:actor, name}, fun)
       when is_binary(name) do
    Workspaces.write_transaction(scope, action, nil, fn scope ->
      with {:ok, resource, actor} <- resource(scope.workspace.id, name, true),
           :ok <- Policy.authorize(scope, action, resource) do
        fun.({:actor, actor}, scope)
      end
    end)
  end

  defp write(_scope, _action, _target, _fun), do: {:error, :forbidden}

  # The identity `name` and the policy resource of its avatar: an agent,
  # or a squad with its current leader (nil for a squad without a squad
  # row). Humans and the system identity never have one. With `lock?`,
  # the identity is locked `FOR UPDATE` and then the squad row `FOR SHARE`
  # (designs/01 §4 order); a squad update locks both `FOR UPDATE`.
  defp resource(workspace_id, name, lock?) do
    query = from(a in Actor, where: a.workspace_id == ^workspace_id and a.name == ^name)

    case Repo.one(if lock?, do: lock(query, "FOR UPDATE"), else: query) do
      nil -> {:error, :not_found}
      %Actor{kind: :agent} = actor -> {:ok, actor, actor}
      %Actor{kind: :squad} = actor -> {:ok, {actor, leader(actor, lock?)}, actor}
      %Actor{} -> {:error, :forbidden}
    end
  end

  defp leader(%Actor{id: id}, lock?) do
    query = from(s in Squad, where: s.actor_id == ^id, select: s.leader_agent_id)

    case Repo.one(if lock?, do: lock(query, "FOR SHARE"), else: query) do
      nil -> nil
      leader_id -> Repo.get(Actor, leader_id)
    end
  end

  defp upsert(owner, scope, data, image) do
    now = DateTime.utc_now()
    key = Avatar.key(data)

    row =
      owner
      |> owner_fields()
      |> Map.merge(%{
        content_type: image.content_type,
        data: data,
        key: key,
        byte_size: byte_size(data),
        edge: image.edge,
        updated_by_id: scope.user.id,
        inserted_at: now,
        updated_at: now
      })

    {1, _} =
      Repo.insert_all(Avatar, [row],
        on_conflict: {:replace, @replaced},
        conflict_target: conflict_target(owner)
      )

    notify(owner)
    {:ok, %{key: key, content_type: image.content_type}}
  end

  defp remove(owner, _scope) do
    {count, _} =
      case owner do
        {:user, %User{id: id}} -> Repo.delete_all(from(a in Avatar, where: a.user_id == ^id))
        {:actor, %Actor{id: id}} -> Repo.delete_all(from(a in Avatar, where: a.actor_id == ^id))
      end

    if count > 0, do: notify(owner)
    {:ok, :ok}
  end

  defp owner_fields({:user, %User{id: id}}), do: %{user_id: id}

  defp owner_fields({:actor, %Actor{id: id, workspace_id: ws}}),
    do: %{workspace_id: ws, actor_id: id}

  defp conflict_target({:user, _user}), do: :user_id
  defp conflict_target({:actor, _actor}), do: :actor_id

  ## Notifications (decision 6), once per transaction and after the commit

  defp notify({:actor, %Actor{workspace_id: ws}}), do: workspace_changed(ws)

  defp notify({:user, %User{id: id}}) do
    from(a in Actor, where: a.user_id == ^id and a.kind == :human, select: a.workspace_id)
    |> Repo.all()
    |> Enum.each(&workspace_changed/1)

    Events.after_commit_once(:avatars, Events.topic(:user, id), {:user_avatar_changed})
  end

  defp workspace_changed(ws),
    do: Events.after_commit_once(:avatars, Events.topic(:workspace, ws), {:avatars_changed})
end

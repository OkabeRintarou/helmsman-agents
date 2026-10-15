defmodule Helmsman.Squads do
  @moduledoc """
  Squads (designs/16 §1, `add-squads`): a `kind = squad` identity with a
  leader (a managed agent) and members (people and managed agents) that
  can be assigned and mentioned like anyone else; its leader runs as the
  squad and hands work to the members.

  Writes (decision 3) lock, in the global order of designs/01 §4: the
  squad identity row `FOR UPDATE` and the identity rows of the leader and
  members `FOR SHARE` (ascending id), the `squads` row `FOR UPDATE`, then
  the profiles of the managed leader and members `FOR SHARE`. The member
  list only changes while the `squads` row is locked `FOR UPDATE`; a
  trigger that reads it holds it `FOR SHARE`. Every change is announced on
  `topic/1` after the commit.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.{Events, Policy, Repo, Runs, Workspaces}
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.{Member, Squad}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  @max_members 16
  @description_bytes 2048
  @instructions_bytes 16_384
  @role_note_bytes 2048
  @trigger_roles [:owner, :admin, :member]

  @type refusal ::
          :squad_disabled
          | :not_managed
          | :agent_archived
          | :agent_disabled
          | :unauthorized
  @type check_result :: :ok | {:error, refusal()} | {:error, :unauthorized, [String.t()]}
  @type trigger_summary :: %{
          able: non_neg_integer(),
          total: non_neg_integer(),
          restricted: [String.t()]
        }

  @typedoc """
  A squad with every row the rules need: its identity, leader (actor and
  profile) and members in order (`profile` nil for a person).
  """
  @type loaded :: %{
          squad: Squad.t(),
          actor: Actor.t(),
          leader: Actor.t(),
          leader_profile: AgentProfile.t() | nil,
          members: [%{member: Member.t(), actor: Actor.t(), profile: AgentProfile.t() | nil}]
        }

  @doc "The PubSub topic of the squads of a workspace: `{:squad, id}` after each change."
  @spec topic(pos_integer()) :: String.t()
  def topic(workspace_id), do: Events.topic(:workspace_squads, workspace_id)

  @doc "Limits of a squad's fields, in UTF-8 bytes, and of its member list."
  @spec limits() :: %{atom() => pos_integer()}
  def limits,
    do: %{
      members: @max_members,
      description: @description_bytes,
      instructions: @instructions_bytes,
      role_note: @role_note_bytes
    }

  ## Reading

  @doc """
  Every squad of the workspace by name (`:view_agents`: viewers too), as
  `get/2` gives them.
  """
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, :forbidden}
  def list(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :view_agents) do
      ids =
        Repo.all(
          from(s in Squad,
            join: a in Actor,
            on: a.id == s.actor_id,
            where: s.workspace_id == ^scope.workspace.id,
            order_by: a.name,
            select: s.id
          )
        )

      {:ok, views(scope, ids)}
    end
  end

  @doc """
  The squad `name` (`:view_agents`): `%{id, name, description,
  instructions, disabled, leader, members, trigger_summary,
  lock_version}` (decision 4), and `busy` (its leader has a claimed,
  running or stopping run as the squad).
  """
  @spec get(Scope.t(), String.t()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  def get(%Scope{} = scope, name) when is_binary(name) do
    with :ok <- Policy.authorize(scope, :view_agents),
         %Squad{id: id} <- by_name(scope.workspace.id, name) do
      {:ok, hd(views(scope, [id]))}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Whether the scope's user may trigger each squad of the workspace
  (decision 4, for the assignee picker): `%{name => :ok | {:skipped,
  reason, refused}}`, `refused` the blocking leader and members
  (`:unauthorized` only, otherwise `[]`).
  """
  @spec availability(Scope.t()) ::
          {:ok, %{String.t() => :ok | {:skipped, refusal(), [String.t()]}}}
          | {:error, :forbidden}
  def availability(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :view_agents) do
      ids = Repo.all(from(s in Squad, where: s.workspace_id == ^scope.workspace.id, select: s.id))
      user_id = scope.user && scope.user.id
      user = {user_id, role_of(scope.workspace.id, user_id)}

      {:ok, Map.new(load_many(ids), &{&1.actor.name, availability_of(&1, user)})}
    end
  end

  defp availability_of(loaded, user) do
    case check_loaded(loaded, user) do
      :ok -> :ok
      {:error, :unauthorized, refused} -> {:skipped, :unauthorized, refused}
      {:error, reason} -> {:skipped, reason, []}
    end
  end

  @doc "Whether `name` is the name of a squad of the workspace `workspace_id`."
  @spec squad_name?(pos_integer(), String.t()) :: boolean()
  def squad_name?(workspace_id, name) when is_binary(name),
    do:
      Repo.exists?(
        from(a in Actor,
          where: a.workspace_id == ^workspace_id and a.name == ^name and a.kind == :squad
        )
      )

  @doc """
  The squad whose identity is `actor_id`, or nil. Does not lock.
  """
  @spec by_actor_id(pos_integer()) :: Squad.t() | nil
  def by_actor_id(actor_id), do: Repo.get_by(Squad, actor_id: actor_id)

  @doc """
  Loads the rows of the squad (`t:loaded/0`) without locking them: the
  caller holds the locks it needs. nil when there is no such squad.
  """
  @spec load(Squad.t() | pos_integer()) :: loaded() | nil
  def load(%Squad{id: id}), do: load(id)

  def load(id) when is_integer(id) do
    case load_many([id]) do
      [loaded] -> loaded
      [] -> nil
    end
  end

  ## Who may trigger a squad (decision 5)

  @doc """
  Whether the user `user_id` may trigger `squad` (a `Squad`, its ID or a
  `t:loaded/0`), designs/16 §1.1: a disabled squad gives
  `:squad_disabled`; the leader is checked by every rule of
  `Helmsman.Agents.TriggerRule.check/3`; each managed member that is
  neither disabled nor archived by its `access`. Blocked leader or members
  give `{:error, :unauthorized, refused}` (names in display order).
  People and disabled members do not count. Reads without locking.
  """
  @spec trigger_check(pos_integer(), pos_integer() | nil, Squad.t() | pos_integer() | loaded()) ::
          check_result()
  def trigger_check(workspace_id, user_id, %{squad: %Squad{}} = loaded),
    do: check_loaded(loaded, {user_id, role_of(workspace_id, user_id)})

  def trigger_check(_workspace_id, _user_id, %Actor{kind: :squad, disabled_at: %DateTime{}}),
    do: {:error, :squad_disabled}

  def trigger_check(workspace_id, user_id, squad) do
    case load(squad) do
      nil -> {:error, :not_managed}
      loaded -> trigger_check(workspace_id, user_id, loaded)
    end
  end

  @doc """
  The rule of `trigger_check/3` on loaded rows, for the user `user_id`
  whose role in the workspace is `role`. Pure.
  """
  @spec check_loaded(loaded(), {pos_integer() | nil, atom() | nil}) :: check_result()
  def check_loaded(%{actor: %Actor{disabled_at: %DateTime{}}}, _user),
    do: {:error, :squad_disabled}

  def check_loaded(loaded, {user_id, role} = user) do
    blocked_members =
      for %{actor: actor, profile: profile} <- active_agent_members(loaded),
          not TriggerRule.may_trigger?(profile, actor, user_id, role),
          do: actor.name

    case TriggerRule.check(loaded.leader_profile, loaded.leader, user) do
      :ok when blocked_members == [] -> :ok
      :ok -> {:error, :unauthorized, blocked_members}
      {:error, :unauthorized} -> {:error, :unauthorized, [loaded.leader.name | blocked_members]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_agent_members(loaded) do
    Enum.filter(loaded.members, fn %{actor: actor, profile: profile} ->
      actor.kind == :agent and not is_nil(profile) and is_nil(profile.archived_at) and
        is_nil(actor.disabled_at)
    end)
  end

  @doc """
  The hint returned when a squad is saved (16 §1.1, decision 3): of the
  `total` people of the workspace who are members or above, `able` may
  trigger the squad (ignoring whether the squad or its leader is disabled
  or archived); `restricted` lists the leader and managed members whose
  `access` is not `workspace`. Takes a `t:loaded/0` or a squad.
  """
  @spec trigger_summary(loaded() | Squad.t() | pos_integer()) :: trigger_summary()
  def trigger_summary(%{squad: %Squad{workspace_id: workspace_id}} = loaded) do
    people =
      Repo.all(
        from(m in Membership,
          where: m.workspace_id == ^workspace_id and m.role in ^@trigger_roles,
          select: {m.user_id, m.role}
        )
      )

    summary(loaded, people)
  end

  def trigger_summary(squad), do: squad |> load() |> trigger_summary()

  defp summary(loaded, people) do
    members = active_agent_members(loaded)

    able =
      Enum.count(people, fn {user_id, role} ->
        TriggerRule.may_trigger?(loaded.leader_profile, loaded.leader, user_id, role) and
          Enum.all?(members, &TriggerRule.may_trigger?(&1.profile, &1.actor, user_id, role))
      end)

    managed =
      [%{actor: loaded.leader, profile: loaded.leader_profile} | loaded.members]
      |> Enum.filter(&(&1.actor.kind == :agent and not is_nil(&1.profile)))

    %{
      able: able,
      total: length(people),
      restricted: for(%{actor: a, profile: p} <- managed, p.access != "workspace", do: a.name)
    }
  end

  @doc """
  The assignee side of `task` (decision 11): the squad identity, its
  current leader and members when the assignee is a squad, otherwise
  `[assignee_id]`, or `[]` without an assignee. Read under the task lock
  the caller holds; locks nothing.
  """
  @spec assignee_side(Task.t()) :: [pos_integer()]
  def assignee_side(%Task{assignee_id: nil}), do: []

  def assignee_side(%Task{assignee_id: id}) do
    case Repo.one(
           from(s in Squad,
             where: s.actor_id == ^id,
             select: {s.id, s.leader_agent_id}
           )
         ) do
      nil ->
        [id]

      {squad_id, leader_id} ->
        members =
          Repo.all(
            from(m in Member,
              where: m.squad_id == ^squad_id,
              order_by: m.position,
              select: m.actor_id
            )
          )

        Enum.uniq([id, leader_id | members])
    end
  end

  ## Writing (decision 3)

  @doc """
  Creates a squad as `scope` (`:manage_squads`: admin and above, or a
  member who owns the leader; never an agent). `attrs`: `name`,
  `description`, `instructions`, `leader` (a name) and `members`
  (`[%{name, role_note}]`). Returns the squad as `get/2` does, with
  `cancelled_runs: []`; `{:error, changeset}` with errors on those
  fields.
  """
  @spec create(Scope.t(), map()) ::
          {:ok, map()} | {:error, Changeset.t() | :forbidden | :not_found}
  def create(%Scope{} = scope, attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    Workspaces.write_transaction(scope, :manage_squads, nil, fn scope ->
      ws = scope.workspace.id
      refs = ws |> lock_refs(nil, attrs) |> with_profiles()

      with :ok <- authorize_leader(scope, refs.leader),
           {:ok, attrs} <-
             validate(attrs, refs, %{leader_id: nil, name_taken: new_name_taken?(ws, attrs)}),
           :ok <- authorize_spec_finalize(scope, %Squad{}, attrs),
           {:ok, actor} <- insert_actor(ws, attrs.name) do
        squad =
          Repo.insert!(%Squad{
            workspace_id: ws,
            actor_id: actor.id,
            leader_agent_id: attrs.leader_id,
            description: attrs.description || "",
            instructions: attrs.instructions || "",
            spec_finalize: spec_finalize(attrs.spec_finalize)
          })

        put_members(squad, attrs.members_resolved || [])
        notify(squad)
        {:ok, squad.id}
      end
    end)
    |> finish(scope, [])
  end

  @doc """
  Changes the squad `name` (decision 3). `attrs` as `create/2`, every key
  optional (`members` replaces the list), and `lock_version`: when given
  and not the current one, `{:error, :stale}`; without it the last write
  wins. Authorized against the current leader, and also the new one when
  it changes. Changing the leader cancels the old leader's pending runs
  as the squad (`obsolete`); the result lists their tasks
  (`cancelled_runs`).
  """
  @spec update(Scope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Changeset.t() | :forbidden | :not_found | :stale}
  def update(%Scope{} = scope, name, attrs) when is_binary(name) and is_map(attrs) do
    attrs = normalize(attrs)

    Workspaces.write_transaction(scope, :manage_squads, nil, fn scope ->
      with {:ok, squad_actor} <- guess_squad_actor(scope.workspace.id, name),
           do: update_locked(scope, name, squad_actor.id, attrs)
    end)
    |> case do
      {:ok, {id, cancelled}} -> finish({:ok, id}, scope, cancelled)
      other -> finish(other, scope, [])
    end
  end

  defp update_locked(scope, name, squad_actor_id, attrs) do
    ws = scope.workspace.id
    refs = lock_refs(ws, squad_actor_id, attrs)
    squad = lock_squad(squad_actor_id)
    # Profiles after the squad row (decision 3).
    refs = with_profiles(refs)
    current_leader = Repo.get!(Actor, squad.leader_agent_id)
    squad_actor = Map.fetch!(refs.locked, squad_actor_id)

    with :ok <- check_name_still(squad_actor, name),
         :ok <- Policy.authorize(scope, :manage_squads, current_leader),
         :ok <- authorize_new_leader(scope, refs.leader, current_leader),
         :ok <- check_version(squad, attrs),
         {:ok, attrs} <-
           validate(attrs, refs, %{
             leader_id: current_leader.id,
             name_taken: renamed_taken?(ws, squad_actor, attrs),
             member_ids: member_ids(squad)
           }),
         :ok <- authorize_spec_finalize(scope, squad, attrs),
         {:ok, _actor} <- rename(squad_actor, attrs.name) do
      cancelled = apply_update(squad, attrs, current_leader)
      notify(squad)
      {:ok, {squad.id, cancelled}}
    end
  end

  @doc """
  Disables the squad `name` (decision 3): its pending leader runs are
  cancelled (`obsolete`), its claimed and running ones stopped; the
  members' delegated runs are left to the claim check.
  """
  @spec disable(Scope.t(), String.t()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  def disable(%Scope{} = scope, name), do: set_disabled(scope, name, true)

  @doc "Enables the squad `name`; nothing is dispatched again."
  @spec enable(Scope.t(), String.t()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  def enable(%Scope{} = scope, name), do: set_disabled(scope, name, false)

  defp set_disabled(scope, name, disabled) do
    Workspaces.write_transaction(scope, :manage_squads, nil, fn scope ->
      ws = scope.workspace.id

      with {:ok, guess} <- guess_squad_actor(ws, name),
           actor = Repo.one!(from(a in Actor, where: a.id == ^guess.id, lock: "FOR UPDATE")),
           squad = lock_squad(actor.id),
           :ok <- check_name_still(actor, name),
           leader = Repo.get!(Actor, squad.leader_agent_id),
           :ok <- Policy.authorize(scope, :manage_squads, leader) do
        put_disabled(actor, squad, disabled)
      end
    end)
    |> finish(scope, [])
  end

  defp put_disabled(actor, squad, disabled) do
    {:ok, _} =
      actor
      |> Changeset.change(disabled_at: if(disabled, do: actor.disabled_at || now_s()))
      |> Repo.update()

    if disabled do
      query = from(r in Run, where: r.squad_id == ^squad.id)
      Runs.cancel_pending(query, :obsolete)
      Runs.stop_active(query)
    end

    notify(squad)
    {:ok, squad.id}
  end

  @doc false
  # Called by `Helmsman.Agents.archive/2` after the agent's identity row
  # is locked `FOR UPDATE` and before its profile is: locks the squads it
  # is a member of `FOR UPDATE` (ascending id) and removes it from them.
  @spec remove_archived_member(Actor.t()) :: :ok
  def remove_archived_member(%Actor{id: actor_id}) do
    member_of = from(m in Member, where: m.actor_id == ^actor_id, select: m.squad_id)

    squad_ids =
      Repo.all(
        from(s in Squad,
          where: s.id in subquery(member_of),
          order_by: s.id,
          lock: "FOR UPDATE",
          select: s.id
        )
      )

    if squad_ids != [] do
      Repo.delete_all(from(m in Member, where: m.actor_id == ^actor_id))

      Repo.update_all(from(s in Squad, where: s.id in ^squad_ids),
        inc: [lock_version: 1],
        set: [updated_at: DateTime.utc_now()]
      )

      for id <- squad_ids, do: Events.after_commit(topic_of(id), {:squad, id})
    end

    :ok
  end

  @doc """
  `delegate(task_id, to, instructions)` of a run as a squad leader
  (decision 8): `Helmsman.Squads.Delegate.delegate/4`.
  """
  defdelegate delegate(scope, task_ident, to, instructions, spec \\ nil),
    to: Helmsman.Squads.Delegate

  ## Write helpers

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %{
      given: attrs |> Map.keys() |> MapSet.new(),
      name: attrs["name"],
      description: attrs["description"],
      instructions: attrs["instructions"],
      leader: attrs["leader"],
      members: attrs["members"],
      lock_version: attrs["lock_version"],
      spec_finalize: attrs["spec_finalize"]
    }
  end

  defp given?(attrs, key), do: MapSet.member?(attrs.given, key)

  defp ref_name(name) when is_binary(name), do: String.downcase(String.trim(name))
  defp ref_name(_name), do: nil

  defp member_names(%{members: members}) when is_list(members),
    do: for(m <- members, is_map(m), name = ref_name(member_field(m, "name")), do: name)

  defp member_names(_attrs), do: []

  defp member_field(m, key), do: Map.get(m, key) || Map.get(m, String.to_existing_atom(key))

  # Guesses the IDs of the named leader and members, locks them with the
  # squad identity (`FOR UPDATE`; the others `FOR SHARE`) by ascending
  # ID, then reads the profiles of the managed ones `FOR SHARE`. A name
  # renamed in between resolves to nothing (reported as not found).
  defp lock_refs(ws, squad_actor_id, attrs) do
    names = Enum.uniq(Enum.reject([ref_name(attrs.leader) | member_names(attrs)], &is_nil/1))

    guessed =
      Repo.all(from(a in Actor, where: a.workspace_id == ^ws and a.name in ^names, select: a.id))

    locked = lock_actors(squad_actor_id, guessed)
    by_name = Map.new(Map.values(locked), &{&1.name, &1})

    %{locked: locked, by_name: by_name, leader: by_name[ref_name(attrs.leader)], profiles: %{}}
  end

  defp lock_actors(squad_actor_id, ids) do
    ids = Enum.sort(Enum.uniq(ids) -- [squad_actor_id])
    {below, above} = Enum.split_with(ids, &(is_nil(squad_actor_id) or &1 < squad_actor_id))

    rows =
      share(below) ++
        if(squad_actor_id,
          do: Repo.all(from(a in Actor, where: a.id == ^squad_actor_id, lock: "FOR UPDATE")),
          else: []
        ) ++ share(above)

    Map.new(rows, &{&1.id, &1})
  end

  defp share([]), do: []

  defp share(ids),
    do: Repo.all(from(a in Actor, where: a.id in ^ids, order_by: a.id, lock: "FOR SHARE"))

  defp with_profiles(refs), do: %{refs | profiles: lock_profiles(Map.values(refs.locked))}

  defp lock_profiles(actors) do
    ids = for %Actor{kind: :agent, id: id} <- actors, do: id

    if ids == [] do
      %{}
    else
      Repo.all(
        from(p in AgentProfile,
          where: p.actor_id in ^ids,
          order_by: p.actor_id,
          lock: "FOR SHARE"
        )
      )
      |> Map.new(&{&1.actor_id, &1})
    end
  end

  # Read while the squad row is locked `FOR UPDATE`.
  defp member_ids(squad),
    do: Repo.all(from(m in Member, where: m.squad_id == ^squad.id, select: m.actor_id))

  defp lock_squad(actor_id),
    do: Repo.one!(from(s in Squad, where: s.actor_id == ^actor_id, lock: "FOR UPDATE"))

  defp guess_squad_actor(ws, name) do
    case Repo.one(
           from(a in Actor,
             where: a.workspace_id == ^ws and a.name == ^ref_name(name) and a.kind == :squad
           )
         ) do
      nil -> {:error, :not_found}
      actor -> {:ok, actor}
    end
  end

  # The squad was renamed between the guess and the lock.
  defp check_name_still(%Actor{name: current}, name) do
    if current == ref_name(name), do: :ok, else: {:error, :not_found}
  end

  defp check_version(%Squad{lock_version: v}, %{lock_version: given})
       when is_integer(given) and given != v,
       do: {:error, :stale}

  defp check_version(_squad, _attrs), do: :ok

  # Creating: the leader asked for. A leader that does not resolve to an
  # identity is a field error reported by `validate/3`.
  defp authorize_leader(_scope, nil), do: :ok
  defp authorize_leader(scope, leader), do: Policy.authorize(scope, :manage_squads, leader)

  defp authorize_new_leader(_scope, nil, _current), do: :ok
  defp authorize_new_leader(_scope, %Actor{id: id}, %Actor{id: id}), do: :ok
  defp authorize_new_leader(scope, leader, _current), do: authorize_leader(scope, leader)

  defp new_name_taken?(ws, %{name: name}) when is_binary(name), do: name_taken?(ws, name, nil)
  defp new_name_taken?(_ws, _attrs), do: false

  defp renamed_taken?(ws, actor, %{name: name}) when is_binary(name),
    do: name != actor.name and name_taken?(ws, name, actor.id)

  defp renamed_taken?(_ws, _actor, _attrs), do: false

  defp name_taken?(ws, name, except_id) do
    query =
      from(a in Actor,
        where: a.workspace_id == ^ws and fragment("lower(?)", a.name) == ^String.downcase(name)
      )

    query = if except_id, do: where(query, [a], a.id != ^except_id), else: query
    Repo.exists?(query)
  end

  defp insert_actor(ws, name) do
    %Actor{workspace_id: ws, kind: :squad}
    |> Actor.create_changeset(%{name: name})
    |> Repo.insert()
    |> field_errors()
  end

  defp rename(actor, name) when is_binary(name) and name != actor.name,
    do: actor |> Actor.rename_changeset(%{name: name}) |> Repo.update() |> field_errors()

  defp rename(actor, _name), do: {:ok, actor}

  defp field_errors({:ok, _} = ok), do: ok

  # The identity's errors (its name taken meanwhile, ...) are `name` errors.
  defp field_errors({:error, %Changeset{errors: errors}}),
    do: {:error, error_changeset(for({_field, {msg, _}} <- errors, do: {:name, msg}))}

  # Validates every field at once; returns `attrs` with `leader_id` and
  # `members_resolved` (`[{actor, role_note}]`, nil when not given).
  defp validate(attrs, refs, %{leader_id: current_leader_id, name_taken: taken?} = ctx) do
    creating? = is_nil(current_leader_id)

    {leader_errors, leader_id} =
      if creating? or given?(attrs, "leader"),
        do: validate_leader(attrs.leader, refs, current_leader_id),
        else: {[], current_leader_id}

    {member_errors, members} =
      if creating? or given?(attrs, "members"),
        do: validate_members(attrs.members, refs, leader_id),
        else: {[], nil}

    errors =
      name_errors(attrs, creating?, taken?) ++
        kept_errors(members, leader_id, current_leader_id, refs, ctx) ++
        validate_text(attrs, "description", @description_bytes) ++
        validate_text(attrs, "instructions", @instructions_bytes) ++
        spec_finalize_errors(attrs) ++ leader_errors ++ member_errors

    case errors do
      [] -> {:ok, Map.merge(attrs, %{leader_id: leader_id, members_resolved: members})}
      errors -> {:error, error_changeset(errors)}
    end
  end

  # `add-spec-workflow` decision 7: nil (inherit the project), `approval`
  # or `leader`.
  defp spec_finalize_errors(attrs) do
    if given?(attrs, "spec_finalize") and spec_finalize(attrs.spec_finalize) == :invalid,
      do: [{:spec_finalize, "must be empty, approval or leader"}],
      else: []
  end

  defp spec_finalize(value) when value in [nil, ""], do: nil
  defp spec_finalize(value) when value in [:approval, "approval"], do: :approval
  defp spec_finalize(value) when value in [:leader, "leader"], do: :leader
  defp spec_finalize(_value), do: :invalid

  # Setting `leader` is for admins; an unchanged value is ignored (decision 7).
  defp authorize_spec_finalize(scope, squad, attrs) do
    if given?(attrs, "spec_finalize") and spec_finalize(attrs.spec_finalize) == :leader and
         squad.spec_finalize != :leader,
       do: Policy.authorize(scope, :set_leader_spec_finalize),
       else: :ok
  end

  defp name_errors(attrs, creating?, taken?) do
    case validate_name(attrs, creating?) do
      [] when taken? -> [{:name, "has already been taken"}]
      errors -> errors
    end
  end

  # A new leader may not stay a member when the list is kept.
  defp kept_errors(nil, leader_id, current_leader_id, refs, ctx)
       when leader_id != current_leader_id do
    if leader_id in Map.get(ctx, :member_ids, []),
      do: [{:leader, "#{refs.leader.name} is a member; remove it from the members first"}],
      else: []
  end

  defp kept_errors(_members, _leader_id, _current, _refs, _ctx), do: []

  defp validate_name(%{name: name}, _creating?) when is_binary(name) do
    if Actor.valid_name?(name) and String.downcase(name) != Actor.system_name(),
      do: [],
      else: [
        {:name,
         if(Actor.valid_name?(name),
           do: "has already been taken",
           else:
             "must be 1-64 characters of a-z, 0-9, '.', '_', '/' and '-', starting with a letter or digit"
         )}
      ]
  end

  defp validate_name(%{name: nil} = attrs, creating?) do
    if creating? or given?(attrs, "name"), do: [{:name, "can't be blank"}], else: []
  end

  defp validate_name(_attrs, _creating?), do: [{:name, "is invalid"}]

  defp validate_text(attrs, key, max) do
    field = String.to_existing_atom(key)

    case Map.fetch!(attrs, field) do
      nil -> []
      text when is_binary(text) and byte_size(text) <= max -> []
      text when is_binary(text) -> [{field, "should be at most #{max} bytes"}]
      _ -> [{field, "is invalid"}]
    end
  end

  defp validate_leader(name, refs, current_leader_id) do
    case refs.leader do
      nil when is_binary(name) and name != "" ->
        {[{:leader, "does not exist"}], nil}

      nil ->
        {[{:leader, "can't be blank"}], nil}

      # Saving with the current leader is allowed even if it was archived
      # since (it is shown as such).
      %Actor{id: ^current_leader_id} ->
        {[], current_leader_id}

      %Actor{} = actor ->
        new_leader(actor, refs.profiles[actor.id])
    end
  end

  defp new_leader(%Actor{kind: :agent, id: id}, %AgentProfile{archived_at: nil}), do: {[], id}

  defp new_leader(%Actor{kind: :agent} = actor, %AgentProfile{}),
    do: {[{:leader, "#{actor.name} is archived"}], nil}

  defp new_leader(actor, _profile), do: {[{:leader, "#{actor.name} is not a managed agent"}], nil}

  defp validate_members(nil, _refs, _leader_id), do: {[], []}

  defp validate_members(members, refs, leader_id) when is_list(members) do
    if length(members) > @max_members do
      {[{:members, "should have at most #{@max_members} members"}], nil}
    else
      {errors, resolved, _seen} =
        Enum.reduce(members, {[], [], MapSet.new()}, &add_member(&1, &2, refs, leader_id))

      {Enum.reverse(errors), Enum.reverse(resolved)}
    end
  end

  defp validate_members(_other, _refs, _leader_id), do: {[{:members, "is invalid"}], nil}

  defp add_member(entry, {errors, resolved, seen}, refs, leader_id) do
    case validate_member(entry, refs, leader_id, seen) do
      {:ok, actor, note} -> {errors, [{actor, note} | resolved], MapSet.put(seen, actor.id)}
      {:error, message} -> {[{:members, message} | errors], resolved, seen}
    end
  end

  defp validate_member(entry, refs, leader_id, seen) when is_map(entry) do
    name = member_field(entry, "name")
    note = member_field(entry, "role_note") || ""

    with {:ok, actor} <- member_actor(name, refs),
         :ok <- member_kind(actor, refs, leader_id),
         :ok <-
           if(MapSet.member?(seen, actor.id),
             do: {:error, "#{actor.name} is listed twice"},
             else: :ok
           ),
         :ok <- member_note(actor, note) do
      {:ok, actor, note}
    end
  end

  defp validate_member(_entry, _refs, _leader_id, _seen), do: {:error, "is invalid"}

  defp member_actor(name, refs) when is_binary(name) do
    case refs.by_name[ref_name(name)] do
      nil -> {:error, "#{name} does not exist"}
      actor -> {:ok, actor}
    end
  end

  defp member_actor(_name, _refs), do: {:error, "is invalid"}

  defp member_kind(%Actor{id: id} = actor, _refs, id),
    do: {:error, "#{actor.name} is the leader"}

  defp member_kind(%Actor{kind: :human}, _refs, _leader_id), do: :ok

  defp member_kind(%Actor{kind: :agent} = actor, refs, _leader_id) do
    case refs.profiles[actor.id] do
      nil -> {:error, "#{actor.name} is not a managed agent"}
      %{archived_at: %DateTime{}} -> {:error, "#{actor.name} is archived"}
      _ -> :ok
    end
  end

  defp member_kind(%Actor{} = actor, _refs, _leader_id),
    do: {:error, "#{actor.name} cannot be a member"}

  defp member_note(_actor, note) when is_binary(note) and byte_size(note) <= @role_note_bytes,
    do: :ok

  defp member_note(actor, note) when is_binary(note),
    do: {:error, "#{actor.name}: the role note should be at most #{@role_note_bytes} bytes"}

  defp member_note(actor, _note), do: {:error, "#{actor.name}: the role note is invalid"}

  defp error_changeset(errors) do
    types = %{
      name: :string,
      description: :string,
      instructions: :string,
      leader: :string,
      members: {:array, :map},
      lock_version: :integer,
      spec_finalize: :string
    }

    Enum.reduce(errors, Changeset.change({%{}, types}), fn {field, message}, cs ->
      Changeset.add_error(cs, field, message)
    end)
    |> Map.put(:action, :validate)
  end

  defp apply_update(squad, attrs, current_leader) do
    changes =
      [
        description: given?(attrs, "description") && (attrs.description || ""),
        instructions: given?(attrs, "instructions") && (attrs.instructions || ""),
        leader_agent_id: attrs.leader_id
      ]
      |> Enum.reject(fn {_k, v} -> v == false end)
      |> Kernel.++(
        if given?(attrs, "spec_finalize"),
          do: [spec_finalize: spec_finalize(attrs.spec_finalize)],
          else: []
      )

    squad
    |> Changeset.change(changes)
    |> Changeset.force_change(:lock_version, squad.lock_version + 1)
    |> Repo.update!()

    if attrs.members_resolved, do: put_members(squad, attrs.members_resolved)

    if attrs.leader_id != current_leader.id,
      do: cancel_leader_runs(squad, current_leader),
      else: []
  end

  # The old leader's pending runs as the squad; their tasks' IDs.
  defp cancel_leader_runs(squad, leader) do
    query = from(r in Run, where: r.squad_id == ^squad.id and r.agent_id == ^leader.id)

    idents =
      Repo.all(
        from(r in query,
          join: t in Task,
          on: t.id == r.task_id,
          where: r.status in ^Run.pending_statuses(),
          order_by: t.id,
          select: t.ident
        )
      )
      |> Enum.uniq()

    Runs.cancel_pending(query, :obsolete)
    idents
  end

  defp put_members(squad, resolved) do
    Repo.delete_all(from(m in Member, where: m.squad_id == ^squad.id))
    now = DateTime.utc_now()

    rows =
      resolved
      |> Enum.with_index()
      |> Enum.map(fn {{actor, note}, i} ->
        %{
          workspace_id: squad.workspace_id,
          squad_id: squad.id,
          actor_id: actor.id,
          role_note: note,
          position: i,
          inserted_at: now
        }
      end)

    Repo.insert_all(Member, rows)
  end

  defp finish({:ok, id}, scope, cancelled) do
    {:ok, scope |> views([id]) |> hd() |> Map.put(:cancelled_runs, cancelled)}
  end

  defp finish(error, _scope, _cancelled), do: error

  defp notify(%Squad{} = squad),
    do: Events.after_commit(topic(squad.workspace_id), {:squad, squad.id})

  defp topic_of(squad_id) do
    workspace_id = Repo.one!(from(s in Squad, where: s.id == ^squad_id, select: s.workspace_id))
    topic(workspace_id)
  end

  defp now_s, do: DateTime.utc_now(:second)

  ## Loading and views

  defp by_name(ws, name) do
    Repo.one(
      from(s in Squad,
        join: a in Actor,
        on: a.id == s.actor_id,
        where: s.workspace_id == ^ws and a.name == ^ref_name(name)
      )
    )
  end

  defp role_of(_ws, nil), do: nil

  defp role_of(ws, user_id),
    do:
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^ws and m.user_id == ^user_id,
          select: m.role
        )
      )

  # Four queries whatever the number of squads.
  defp load_many([]), do: []

  defp load_many(ids) do
    squads = Repo.all(from(s in Squad, where: s.id in ^ids))

    members =
      Repo.all(from(m in Member, where: m.squad_id in ^ids, order_by: [m.squad_id, m.position]))

    actor_ids =
      Enum.flat_map(squads, &[&1.actor_id, &1.leader_agent_id]) ++
        Enum.map(members, & &1.actor_id)

    actors = Map.new(Repo.all(from(a in Actor, where: a.id in ^actor_ids)), &{&1.id, &1})

    profiles =
      Map.new(
        Repo.all(from(p in AgentProfile, where: p.actor_id in ^actor_ids)),
        &{&1.actor_id, &1}
      )

    members_by = Enum.group_by(members, & &1.squad_id)
    order = ids |> Enum.with_index() |> Map.new()

    squads
    |> Enum.sort_by(&order[&1.id])
    |> Enum.map(fn squad ->
      %{
        squad: squad,
        actor: actors[squad.actor_id],
        leader: actors[squad.leader_agent_id],
        leader_profile: profiles[squad.leader_agent_id],
        members:
          for m <- Map.get(members_by, squad.id, []) do
            %{member: m, actor: actors[m.actor_id], profile: profiles[m.actor_id]}
          end
      }
    end)
  end

  defp views(scope, ids) do
    ws = scope.workspace.id
    loaded = load_many(ids)

    people =
      Repo.all(
        from(m in Membership,
          where: m.workspace_id == ^ws and m.role in ^@trigger_roles,
          select: {m.user_id, m.role}
        )
      )

    owner_ids = loaded |> Enum.map(& &1.leader.owner_id) |> Enum.uniq()

    owners =
      Map.new(
        Repo.all(from(u in User, where: u.id in ^owner_ids, select: {u.id, u.display_name}))
      )

    busy =
      Repo.all(
        from(r in Run,
          where: r.squad_id in ^ids and r.status in ^Run.active_statuses(),
          distinct: true,
          select: r.squad_id
        )
      )
      |> MapSet.new()

    Enum.map(
      loaded,
      &Map.put(view(&1, people, owners, busy), :can_manage, can_manage?(scope, &1))
    )
  end

  defp view(loaded, people, owners, busy) do
    %{squad: squad, actor: actor, leader: leader, leader_profile: lp} = loaded

    %{
      id: squad.id,
      actor_id: actor.id,
      name: actor.name,
      description: squad.description,
      instructions: squad.instructions,
      # nil: the project's mode applies (`add-spec-workflow` decision 7).
      spec_finalize: squad.spec_finalize,
      disabled: not is_nil(actor.disabled_at),
      lock_version: squad.lock_version,
      leader: %{
        name: leader.name,
        provider: lp && lp.provider,
        model: lp && lp.model,
        effort: lp && lp.effort,
        disabled: not is_nil(leader.disabled_at),
        archived: (lp && not is_nil(lp.archived_at)) || false,
        owner: %{id: leader.owner_id, name: owners[leader.owner_id]}
      },
      members: Enum.map(loaded.members, &member_view/1),
      trigger_summary: summary(loaded, people),
      busy: MapSet.member?(busy, squad.id)
    }
  end

  # What the scope may do with the squad (#36 domain-request-1 R1): the
  # resource rule of `:manage_squads` on the current leader.
  defp can_manage?(scope, loaded),
    do: Policy.authorize(scope, :manage_squads, loaded.leader) == :ok

  defp member_view(%{member: m, actor: actor, profile: profile}) do
    %{
      name: actor.name,
      kind: Atom.to_string(actor.kind),
      role_note: m.role_note,
      provider: profile && profile.provider,
      model: profile && profile.model,
      effort: profile && profile.effort,
      description: profile && profile.description,
      disabled: not is_nil(actor.disabled_at)
    }
  end
end

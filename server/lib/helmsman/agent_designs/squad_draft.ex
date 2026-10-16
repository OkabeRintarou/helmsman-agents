defmodule Helmsman.AgentDesigns.SquadDraft do
  @moduledoc """
  The squad part of a `squad` conversation's draft (`add-squads` decision
  12): `draft["squad"]` is `%{"name", "description", "leader",
  "instructions", "members" => [%{"name", "role_note"}]}`, `name` and
  `leader` nil until given.

  `put/4` patches it (`propose_squad`, the user's edits): given fields
  replace, `members` as a whole, `nil` restores the default. Names
  resolve to the draft's new agents first (case-insensitive), then to the
  workspace's identities; the checks are those of `Helmsman.Squads`: the
  leader is a managed agent (a draft agent is one), members are people or
  managed agents, not the leader, not twice, at most
  #{16}; the lengths in bytes; the squad's name is not taken by an
  identity of the workspace or an agent of the draft.
  """

  import Ecto.Query

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.Draft
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.Repo
  alias Helmsman.Squads
  alias Helmsman.Workspaces.Membership

  @fields ~w(name description leader instructions members)
  @defaults %{
    "name" => nil,
    "description" => "",
    "leader" => nil,
    "instructions" => "",
    "members" => []
  }
  @trigger_roles [:owner, :admin, :member]

  @doc "The squad part of a new `squad` conversation's draft."
  @spec empty() :: map()
  def empty, do: @defaults

  @doc "The fields of the squad part, in a stable order."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "The squad part of `draft`, or nil (an `agent` conversation)."
  @spec get(map()) :: map() | nil
  def get(%{"squad" => %{} = squad}), do: squad
  def get(_draft), do: nil

  @doc """
  Patches the squad part of `draft` with `attrs` for the conversation's
  user `user_scope`. `{:ok, draft, squad, fields}` (`fields`: those that
  changed) or `{:error, changeset}` (schemaless, errors on `name`,
  `description`, `leader`, `instructions`, `members`, or `base` for an
  unknown key).
  """
  @spec put(map(), map(), Scope.t(), keyword()) ::
          {:ok, map(), map(), [String.t()]} | {:error, Ecto.Changeset.t()}
  def put(draft, attrs, %Scope{} = user_scope, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    current = get(draft) || @defaults

    squad =
      Enum.reduce(@fields, current, fn field, acc ->
        case Map.fetch(attrs, field) do
          {:ok, nil} -> Map.put(acc, field, @defaults[field])
          {:ok, value} -> Map.put(acc, field, normalize(field, value))
          :error -> acc
        end
      end)

    unknown = attrs |> Map.keys() |> Enum.reject(&(&1 in @fields)) |> Enum.sort()

    case unknown_errors(unknown) ++ errors(squad, draft, user_scope, opts) do
      [] ->
        changed = Enum.filter(@fields, &(Map.get(current, &1) != Map.get(squad, &1)))
        {:ok, Map.put(draft, "squad", squad), squad, changed}

      errors ->
        {:error, changeset(errors)}
    end
  end

  defp normalize("members", members) when is_list(members) do
    Enum.map(members, fn
      %{} = m ->
        m = Map.new(m, fn {k, v} -> {to_string(k), v} end)
        %{"name" => m["name"], "role_note" => m["role_note"] || ""}

      other ->
        other
    end)
  end

  defp normalize(_field, value), do: value

  defp unknown_errors(keys),
    do: Enum.map(keys, &{:base, {"%{field} is not a squad field", [field: &1]}})

  @doc """
  The errors of the squad part `squad` of `draft`, as
  `[{field, {message, opts}}]`. `require: true` (confirming) also needs
  `name` and `leader`; `fixed_name: true` (an edit conversation, whose
  name is the existing squad's) skips the name's checks.
  """
  @spec errors(map(), map(), Scope.t(), keyword()) :: [{atom(), {String.t(), keyword()}}]
  def errors(squad, draft, %Scope{} = user_scope, opts \\ []) do
    ws = user_scope.workspace.id
    refs = resolve(squad, draft, ws)

    if(opts[:fixed_name], do: [], else: name_errors(squad["name"], draft, ws, opts)) ++
      text_errors(squad, "description", Squads.limits().description) ++
      text_errors(squad, "instructions", Squads.limits().instructions) ++
      leader_errors(squad["leader"], refs, opts) ++
      member_errors(squad["members"], squad["leader"], refs)
  end

  defp name_errors(nil, _draft, _ws, opts),
    do: if(opts[:require], do: [{:name, {"can't be blank", []}}], else: [])

  defp name_errors(name, draft, ws, _opts) when is_binary(name) do
    cond do
      not Actor.valid_name?(name) ->
        [
          {:name,
           {"must be 1-64 characters of a-z, 0-9, '.', '_', '/' and '-', starting with a letter or digit",
            []}}
        ]

      String.downcase(name) == Actor.system_name() or taken?(ws, name) ->
        [{:name, {"has already been taken", []}}]

      Draft.find(draft, name) ->
        [{:name, {"is the name of an agent in the draft", []}}]

      true ->
        []
    end
  end

  defp name_errors(_name, _draft, _ws, _opts), do: [{:name, {"is invalid", []}}]

  defp taken?(ws, name),
    do:
      Repo.exists?(
        from(a in Actor,
          where: a.workspace_id == ^ws and fragment("lower(?)", a.name) == ^String.downcase(name)
        )
      )

  defp text_errors(squad, field, max) do
    case squad[field] do
      text when is_binary(text) and byte_size(text) <= max ->
        []

      text when is_binary(text) ->
        [{String.to_existing_atom(field), {"should be at most #{max} bytes", []}}]

      _ ->
        [{String.to_existing_atom(field), {"is invalid", []}}]
    end
  end

  # Each referenced name: `{:new, entry}` (a draft agent), `{:actor,
  # actor, profile}` or nil.
  defp resolve(squad, draft, ws) do
    names =
      [squad["leader"] | Enum.map(List.wrap(squad["members"]), &member_name/1)]
      |> Enum.filter(&is_binary/1)

    existing =
      Repo.all(
        from(a in Actor,
          left_join: p in AgentProfile,
          on: p.actor_id == a.id,
          where: a.workspace_id == ^ws and a.name in ^Enum.map(names, &String.downcase/1),
          select: {a, p}
        )
      )
      |> Map.new(fn {a, p} -> {a.name, {:actor, a, p}} end)

    Map.new(names, fn name ->
      case Draft.find(draft, name) do
        nil -> {name, existing[String.downcase(name)]}
        entry -> {name, {:new, entry}}
      end
    end)
  end

  defp member_name(%{"name" => name}), do: name
  defp member_name(_member), do: nil

  defp leader_errors(nil, _refs, opts),
    do: if(opts[:require], do: [{:leader, {"can't be blank", []}}], else: [])

  defp leader_errors(name, refs, _opts) when is_binary(name) do
    case refs[name] do
      nil ->
        [{:leader, {"%{name} does not exist", [name: name]}}]

      {:new, _entry} ->
        []

      ref ->
        if managed?(ref),
          do: [],
          else: [{:leader, {"%{name} is not a managed agent", [name: name]}}]
    end
  end

  defp leader_errors(_name, _refs, _opts), do: [{:leader, {"is invalid", []}}]

  defp managed?({:actor, %Actor{kind: :agent}, %AgentProfile{archived_at: nil}}), do: true
  defp managed?(_ref), do: false

  defp member_errors(members, leader, refs) when is_list(members) do
    if length(members) > Squads.limits().members do
      [{:members, {"should have at most %{count} members", [count: Squads.limits().members]}}]
    else
      {errors, _seen} =
        Enum.reduce(members, {[], MapSet.new()}, &add_member(&1, &2, leader, refs))

      Enum.reverse(errors)
    end
  end

  defp member_errors(_members, _leader, _refs), do: [{:members, {"is invalid", []}}]

  defp add_member(member, {errors, seen}, leader, refs) do
    case member_error(member, leader, refs, seen) do
      {:ok, key} -> {errors, MapSet.put(seen, key)}
      {:error, message, opts} -> {[{:members, {message, opts}} | errors], seen}
    end
  end

  defp member_error(%{"name" => name, "role_note" => note}, leader, refs, seen)
       when is_binary(name) do
    key = String.downcase(name)

    cond do
      is_binary(leader) and key == String.downcase(leader) ->
        {:error, "%{name} is the leader", [name: name]}

      MapSet.member?(seen, key) ->
        {:error, "%{name} is listed twice", [name: name]}

      not is_binary(note) ->
        {:error, "the role note of %{name} is invalid", [name: name]}

      byte_size(note) > Squads.limits().role_note ->
        {:error, "the role note of %{name} should be at most %{count} bytes",
         [name: name, count: Squads.limits().role_note]}

      true ->
        member_kind(name, key, refs[name])
    end
  end

  defp member_error(_member, _leader, _refs, _seen), do: {:error, "is invalid", []}

  defp member_kind(name, _key, nil), do: {:error, "%{name} does not exist", [name: name]}
  defp member_kind(_name, key, {:new, _entry}), do: {:ok, key}
  defp member_kind(_name, key, {:actor, %Actor{kind: :human}, _profile}), do: {:ok, key}

  defp member_kind(name, key, ref) do
    if managed?(ref), do: {:ok, key}, else: {:error, "%{name} cannot be a member", [name: name]}
  end

  defp changeset(errors) do
    types = %{
      name: :string,
      description: :string,
      leader: :string,
      instructions: :string,
      members: {:array, :map}
    }

    %Ecto.Changeset{data: %{}, types: types, valid?: false, errors: errors}
  end

  @doc """
  The squad part with every reference to the draft agent `from` renamed
  to `to` (a `propose_agent` rename).
  """
  @spec rename(map(), String.t(), String.t()) :: map()
  def rename(%{"squad" => %{} = squad} = draft, from, to) do
    same? = &(is_binary(&1) and String.downcase(&1) == String.downcase(from))

    squad =
      squad
      |> Map.update("leader", nil, &if(same?.(&1), do: to, else: &1))
      |> Map.update("members", [], fn members ->
        Enum.map(members, &if(same?.(&1["name"]), do: Map.put(&1, "name", to), else: &1))
      end)

    Map.put(draft, "squad", squad)
  end

  def rename(draft, _from, _to), do: draft

  @doc "Whether the squad part refers to the draft agent `name`."
  @spec references?(map(), String.t()) :: boolean()
  def references?(draft, name) do
    case get(draft) do
      nil ->
        false

      squad ->
        key = String.downcase(name)

        [squad["leader"] | Enum.map(List.wrap(squad["members"]), &member_name/1)]
        |> Enum.any?(&(is_binary(&1) and String.downcase(&1) == key))
    end
  end

  @doc """
  The hint of the squad part (decision 12): as `Helmsman.Squads.trigger_summary/1`,
  the draft's new agents counted with their `access` and the
  conversation's user as their owner. Unresolved names are left out.
  """
  @spec trigger_summary(map(), Scope.t()) :: Squads.trigger_summary()
  def trigger_summary(draft, %Scope{} = user_scope) do
    squad = get(draft) || @defaults
    ws = user_scope.workspace.id
    refs = resolve(squad, draft, ws)

    leader =
      if is_binary(squad["leader"]), do: agent_rule(refs[squad["leader"]], user_scope), else: []

    members =
      squad["members"]
      |> List.wrap()
      |> Enum.map(&member_name/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&agent_rule(refs[&1], user_scope))

    # As `Helmsman.Squads.trigger_summary/1`: a disabled member does not
    # count for who may trigger, the leader always does.
    managed = leader ++ Enum.reject(members, fn {_name, _profile, actor} -> actor.disabled_at end)

    people =
      Repo.all(
        from(m in Membership,
          where: m.workspace_id == ^ws and m.role in ^@trigger_roles,
          select: {m.user_id, m.role}
        )
      )

    able =
      Enum.count(people, fn {user_id, role} ->
        Enum.all?(managed, fn {_name, profile, actor} ->
          TriggerRule.may_trigger?(profile, actor, user_id, role)
        end)
      end)

    %{
      able: able,
      total: length(people),
      restricted: for({name, p, _a} <- leader ++ members, p.access != "workspace", do: name)
    }
  end

  defp agent_rule({:new, entry}, user_scope) do
    profile = %AgentProfile{access: entry["access"] || "owner_only", access_member_ids: []}
    [{entry["name"], profile, %Actor{kind: :agent, owner_id: user_scope.user.id}}]
  end

  defp agent_rule({:actor, %Actor{kind: :agent} = actor, %AgentProfile{} = profile}, _scope),
    do: [{actor.name, profile, actor}]

  defp agent_rule(_ref, _scope), do: []
end

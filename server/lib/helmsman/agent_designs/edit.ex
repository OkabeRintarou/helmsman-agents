defmodule Helmsman.AgentDesigns.Edit do
  @moduledoc """
  Edit conversations (`add-edit-design-conversations` decisions 4–8, 10):
  `agent_edit` changes an existing managed agent, `squad_edit` a squad
  (and may add new agents to it). The target is the conversation's
  `target_actor_id`, whatever its name now; the `baseline` is the target's
  draft fields when the conversation started (a squad also its
  `lock_version`), and the draft starts equal to it.

    * `agent_edit`: the draft is `%{"agents" => [entry]}`, the one entry
      the target (its name fixed). Its owner may change every draft field;
      an admin who is not the owner only `description`, `max_concurrency`,
      `timeout_minutes` and `idle_timeout_minutes` (12 §2), the rest is
      read-only. Runtime and provider account are the owner's. A field the
      draft and the baseline both changed since a rebaseline is in the
      entry's `conflicts` until written again.
    * `squad_edit`: the draft is `%{"agents" => [new agents], "squad" =>
      squad part}`; the squad's name is fixed, the new agents are owned by
      the user, and an existing identity cannot be one of them.

  The user's rights (`rights/1`) are read without locks: on the run side
  the conversation row is already locked and the membership row comes
  before it (decision 5); the confirm checks them again under the lock.
  Someone other than the owner sees provider accounts as name and host
  only (`present/2`).
  """

  import Ecto.Query

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.{AgentDesign, Changes, Draft, SquadDraft}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Policy
  alias Helmsman.ProviderAccounts
  alias Helmsman.Repo
  alias Helmsman.Squads.{Member, Squad}
  alias Helmsman.Workspaces.Membership

  @admin_fields ~w(description max_concurrency timeout_minutes idle_timeout_minutes)
  @lifecycle ~w(disabled enabled archived deleted disable enable archive delete)
  @member_roles [:owner, :admin, :member]
  @admin_roles [:owner, :admin]

  @type rights :: :owner | :admin | :manager | :none

  @doc "The fields an admin who is not the owner may change (12 §2)."
  @spec admin_fields() :: [String.t()]
  def admin_fields, do: @admin_fields

  ## Starting

  @doc """
  The kind of an edit conversation on the identity `name` of the
  workspace (read without a lock; an identity never changes kind):
  `{:ok, :agent_edit | :squad_edit}` or `{:error, :not_found}` (no such
  identity, a person, an external or archived agent).
  """
  @spec kind_of(pos_integer(), term()) :: {:ok, :agent_edit | :squad_edit} | {:error, :not_found}
  def kind_of(workspace_id, name) when is_binary(name) do
    case target_by_name(workspace_id, name) do
      {%Actor{kind: :agent}, %AgentProfile{archived_at: nil}} -> {:ok, :agent_edit}
      {%Actor{kind: :squad}, _profile} -> {:ok, :squad_edit}
      _other -> {:error, :not_found}
    end
  end

  def kind_of(_workspace_id, _name), do: {:error, :not_found}

  defp target_by_name(workspace_id, name) do
    Repo.one(
      from(a in Actor,
        left_join: p in AgentProfile,
        on: p.actor_id == a.id,
        where: a.workspace_id == ^workspace_id and a.name == ^name,
        select: {a, p}
      )
    )
  end

  @doc """
  In the start's transaction (the user's membership row held `FOR
  SHARE`): checks that `scope` may start a `kind` conversation on `name`
  and reads the baseline. `{:ok, draft, fields}` for
  `AgentDesigns.start_conversation/4`; `:not_found` or `:forbidden`.
  """
  @spec open(Scope.t(), :agent_edit | :squad_edit, String.t()) ::
          {:ok, map(), keyword()} | {:error, :not_found | :forbidden}
  def open(%Scope{} = scope, :agent_edit, name) do
    case target_by_name(scope.workspace.id, name) do
      {%Actor{kind: :agent} = actor, %AgentProfile{archived_at: nil} = profile} ->
        with :ok <- Policy.authorize(scope, :administer_agent, actor) do
          fields = agent_fields(actor, profile)

          {:ok, %{"agents" => [Map.put(fields, "updated_by", nil)]},
           [target_actor_id: actor.id, baseline: %{"agent" => fields}]}
        end

      _other ->
        {:error, :not_found}
    end
  end

  def open(%Scope{} = scope, :squad_edit, name) do
    case target_by_name(scope.workspace.id, name) do
      {%Actor{kind: :squad} = actor, _profile} ->
        squad = Repo.get_by!(Squad, actor_id: actor.id)
        leader = Repo.get!(Actor, squad.leader_agent_id)

        with :ok <- Policy.authorize(scope, :manage_squads, leader) do
          baseline = squad_baseline(actor.id)
          squad_part = Map.merge(baseline["squad"], %{"name" => actor.name})

          {:ok, %{"agents" => [], "squad" => squad_part},
           [target_actor_id: actor.id, baseline: baseline]}
        end

      _other ->
        {:error, :not_found}
    end
  end

  @doc """
  The target `name` of a `kind` conversation if `scope` may start one on it
  (as `open/3`, without reading the baseline): `{:ok, actor}`, `:not_found`
  or `:forbidden`.
  """
  @spec authorize(Scope.t(), :agent_edit | :squad_edit, String.t()) ::
          {:ok, Actor.t()} | {:error, :not_found | :forbidden}
  def authorize(%Scope{} = scope, :agent_edit, name) do
    case target_by_name(scope.workspace.id, name) do
      {%Actor{kind: :agent} = actor, %AgentProfile{archived_at: nil}} ->
        with :ok <- Policy.authorize(scope, :administer_agent, actor), do: {:ok, actor}

      _other ->
        {:error, :not_found}
    end
  end

  def authorize(%Scope{} = scope, :squad_edit, name) do
    case target_by_name(scope.workspace.id, name) do
      {%Actor{kind: :squad} = actor, _profile} ->
        squad = Repo.get_by!(Squad, actor_id: actor.id)
        leader = Repo.get!(Actor, squad.leader_agent_id)
        with :ok <- Policy.authorize(scope, :manage_squads, leader), do: {:ok, actor}

      _other ->
        {:error, :not_found}
    end
  end

  @doc "The draft fields of the managed agent `actor` with `profile` (string keys)."
  @spec agent_fields(Actor.t(), AgentProfile.t()) :: map()
  def agent_fields(%Actor{} = actor, %AgentProfile{} = profile) do
    profile
    |> Map.take(Enum.map(Changes.agent_fields(), &String.to_existing_atom/1))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("name", actor.name)
    |> Map.put(
      "mcp_servers",
      Enum.map(Map.get(Helmsman.McpServers.references([actor.id]), actor.id, []), & &1.name)
    )
  end

  @doc """
  The baseline of the squad whose identity is `actor_id`: `%{"squad" =>
  %{description, instructions, leader, members: [%{name, role_note}]},
  "lock_version" => n}` (members in their order), or nil. Reads without
  locks: the caller holds the ones it needs.
  """
  @spec squad_baseline(pos_integer()) :: map() | nil
  def squad_baseline(actor_id) do
    case Repo.one(
           from(s in Squad,
             join: l in Actor,
             on: l.id == s.leader_agent_id,
             where: s.actor_id == ^actor_id,
             select: {s, l.name}
           )
         ) do
      nil ->
        nil

      {squad, leader} ->
        members =
          Repo.all(
            from(m in Member,
              join: a in Actor,
              on: a.id == m.actor_id,
              where: m.squad_id == ^squad.id,
              order_by: [asc: m.position, asc: a.name],
              select: %{"name" => a.name, "role_note" => m.role_note}
            )
          )
          |> Enum.map(&Map.update!(&1, "role_note", fn note -> note || "" end))

        %{
          "squad" => %{
            "description" => squad.description || "",
            "instructions" => squad.instructions || "",
            "leader" => leader,
            "members" => members
          },
          "lock_version" => squad.lock_version
        }
    end
  end

  ## Rights (read without locks)

  @doc """
  The rights of the conversation's user on its target, read now without
  locks: `agent_edit` `:owner` (a member or above who owns it), `:admin`
  (an admin or above who does not) or `:none`; `squad_edit` `:manager`
  (`:manage_squads` on the current leader) or `:none`. Also the target's
  owner name (`agent_edit`).
  """
  @spec rights(AgentDesign.t()) :: {rights(), String.t() | nil}
  def rights(%AgentDesign{kind: :agent_edit} = design) do
    role = role(design)

    case Repo.one(
           from(a in Actor,
             join: u in assoc(a, :owner),
             left_join: p in AgentProfile,
             on: p.actor_id == a.id,
             where: a.id == ^design.target_actor_id,
             select: {a.owner_id, u.display_name, p.archived_at}
           )
         ) do
      {_owner, name, archived} when not is_nil(archived) -> {:none, name}
      {owner, name, nil} when owner == design.user_id and role in @member_roles -> {:owner, name}
      {_owner, name, nil} when role in @admin_roles -> {:admin, name}
      {_owner, name, _archived} -> {:none, name}
      nil -> {:none, nil}
    end
  end

  def rights(%AgentDesign{kind: :squad_edit} = design) do
    role = role(design)

    owner =
      Repo.one(
        from(s in Squad,
          join: l in Actor,
          on: l.id == s.leader_agent_id,
          where: s.actor_id == ^design.target_actor_id,
          select: l.owner_id
        )
      )

    cond do
      is_nil(owner) -> {:none, nil}
      role in @admin_roles -> {:manager, nil}
      role in @member_roles and owner == design.user_id -> {:manager, nil}
      true -> {:none, nil}
    end
  end

  defp role(design),
    do:
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^design.workspace_id and m.user_id == ^design.user_id,
          select: m.role
        )
      )

  @doc "The read-only draft fields of `design` for `rights`."
  @spec readonly(AgentDesign.t(), rights()) :: [String.t()]
  def readonly(%AgentDesign{kind: :agent_edit}, :admin),
    do: Changes.agent_fields() -- @admin_fields

  def readonly(%AgentDesign{kind: :agent_edit}, :owner), do: []
  def readonly(%AgentDesign{kind: :agent_edit}, _none), do: Changes.agent_fields()
  def readonly(_design, _rights), do: []

  @doc "The target's current name (nil when it is gone)."
  @spec target_name(AgentDesign.t()) :: String.t() | nil
  def target_name(%AgentDesign{target_actor_id: id}),
    do: Repo.one(from(a in Actor, where: a.id == ^id, select: a.name))

  ## Writing the draft

  @doc """
  `propose_agent` / the user's agent edit in an edit conversation.
  `agent_edit`: patches the target's entry (decision 7); `squad_edit`: a
  new agent only (`Draft.put/4`). `{:ok, draft, entry, edit}` or `{:error,
  changeset | :draft_full | :forbidden}`.
  """
  @spec put_agent(AgentDesign.t(), map(), Scope.t(), String.t()) ::
          {:ok, map(), map(), map() | nil} | {:error, term()}
  def put_agent(%AgentDesign{kind: :agent_edit} = design, attrs, _user_scope, by) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case rights(design) do
      {:none, _owner} -> {:error, :forbidden}
      {rights, owner} -> put_target(design, attrs, rights, owner, by)
    end
  end

  def put_agent(%AgentDesign{kind: :squad_edit} = design, attrs, user_scope, by) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    name = attrs["name"]

    cond do
      elem(rights(design), 0) == :none ->
        {:error, :forbidden}

      is_nil(Draft.find(design.draft, attrs["previous_name"] || name)) and
          existing?(design.workspace_id, name) ->
        {:error,
         error_changeset([
           {:name,
            {"%{name} is an existing agent; edit it in its own conversation", [name: name]}}
         ])}

      true ->
        Draft.put(design.draft, attrs, user_scope, by)
    end
  end

  defp existing?(workspace_id, name) when is_binary(name),
    do:
      Repo.exists?(
        from(a in Actor,
          where:
            a.workspace_id == ^workspace_id and
              fragment("lower(?)", a.name) == ^String.downcase(name)
        )
      )

  defp existing?(_workspace_id, _name), do: false

  defp put_target(design, attrs, rights, owner, by) do
    [entry] = Draft.agents(design.draft)
    baseline = design.baseline["agent"]
    given = Map.take(attrs, Changes.agent_fields())
    keys = given |> Map.keys() |> Enum.sort()

    errors =
      name_errors(design, attrs, baseline) ++
        key_errors(attrs) ++
        readonly_errors(keys, rights, owner)

    with [] <- errors,
         {:ok, patched} <- cast(entry, given),
         [] <- rule_errors(patched, baseline) ++ profile_errors(design, patched) do
      conflicts = List.wrap(entry["conflicts"]) -- keys

      stored =
        patched
        |> Map.put("name", entry["name"])
        |> Map.put("updated_by", by)
        |> put_conflicts(conflicts)

      changed = Enum.filter(Changes.agent_fields(), &(Map.get(entry, &1) != Map.get(stored, &1)))
      edit = if changed != [], do: %{"agent" => entry["name"], "fields" => Enum.sort(changed)}
      {:ok, %{design.draft | "agents" => [stored]}, stored, edit}
    else
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      errors when is_list(errors) -> {:error, error_changeset(errors)}
    end
  end

  @rename "agents cannot be renamed in a conversation; rename it on the agent's page"

  defp name_errors(design, attrs, baseline) do
    names = Enum.reject([target_name(design), baseline["name"]], &is_nil/1)
    name = attrs["name"]

    cond do
      Map.has_key?(attrs, "previous_name") -> [{:name, {@rename, []}}]
      is_binary(name) and Enum.any?(names, &same?(&1, name)) -> []
      true -> [{:name, {@rename, []}}]
    end
  end

  defp key_errors(attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in Draft.fields() or &1 == "previous_name"))
    |> Enum.sort()
    |> Enum.map(fn key ->
      cond do
        key in @lifecycle ->
          {:base,
           {"%{field} cannot be changed in a conversation; do it on the agent's page",
            [field: key]}}

        key in Draft.refused() ->
          {String.to_existing_atom(key), {"cannot be set in a draft", []}}

        true ->
          {:base, {"%{field} is not a draft field", [field: key]}}
      end
    end)
  end

  defp readonly_errors(_keys, :owner, _owner), do: []

  defp readonly_errors(keys, :admin, owner) do
    for key <- keys, key not in @admin_fields do
      {String.to_existing_atom(key),
       {"only the owner (%{owner}) can change this field", [owner: owner]}}
    end
  end

  # The given fields replace, `nil` restores the default (as creating).
  defp cast(entry, given) do
    types = Draft.types()
    keys = given |> Map.keys() |> Enum.map(&String.to_existing_atom/1)
    base = Map.new(Map.keys(types), &{&1, Map.get(entry, Atom.to_string(&1))})
    defaults = Draft.defaults()

    cs =
      {base, types}
      |> Ecto.Changeset.cast(given, keys, empty_values: [])
      |> Ecto.Changeset.validate_required([:provider, :instructions])

    if cs.valid? do
      changes =
        Map.new(cs.changes, fn {k, v} ->
          key = Atom.to_string(k)
          {key, if(is_nil(v) and Map.has_key?(defaults, key), do: defaults[key], else: v)}
        end)

      patched =
        entry
        |> Map.take(Draft.fields())
        |> Map.merge(changes)
        |> Map.update("model", nil, &blank_nil/1)
        |> Map.update("effort", nil, &blank_nil/1)

      {:ok, patched}
    else
      {:error, cs}
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  # `members` (its list is not in the draft) only kept from the baseline;
  # the capabilities are the profile's (only `create_tasks`).
  defp rule_errors(entry, baseline) do
    if entry["access"] in ["owner_only", "workspace"] or
         (entry["access"] == "members" and baseline["access"] == "members"),
       do: [],
       else: [{:access, {"must be owner_only or workspace", []}}]
  end

  # As editing the managed agent: its profile's changeset, the runtime and
  # account the owner's (`AgentProfile.changeset/3` with the target).
  defp profile_errors(design, entry) do
    actor = Repo.get!(Actor, design.target_actor_id)
    profile = Repo.get_by!(AgentProfile, actor_id: actor.id)
    attrs = Map.take(entry, Changes.agent_fields()) |> Map.delete("mcp_servers")

    refs =
      if entry["mcp_servers"] != design.baseline["agent"]["mcp_servers"],
        do:
          Helmsman.McpServers.resolve_names(%{user: %{id: actor.owner_id}}, entry["mcp_servers"]),
        else: {:ok, nil}

    case refs do
      {:error, message} ->
        [{:mcp_servers, {message, []}}]

      {:ok, ids} ->
        attrs = if ids, do: Map.put(attrs, "mcp_server_ids", ids), else: attrs

        profile
        |> AgentProfile.changeset(attrs, actor)
        |> AgentProfile.scrub()
        |> Map.fetch!(:errors)
        |> Enum.reject(fn {field, _error} -> field in [:actor_id, :access_member_ids] end)
        |> Enum.map(fn {field, error} ->
          {if(field == :mcp_server_ids, do: :mcp_servers, else: field), error}
        end)
    end
  end

  defp put_conflicts(entry, []), do: Map.delete(entry, "conflicts")
  defp put_conflicts(entry, conflicts), do: Map.put(entry, "conflicts", Enum.sort(conflicts))

  @doc """
  `propose_squad` / the user's squad edit in a `squad_edit` conversation:
  as in a squad conversation, but the name is fixed (a different one is a
  `name` error). `{:ok, draft, squad, fields}` or `{:error, changeset |
  :forbidden}`.
  """
  @spec put_squad(AgentDesign.t(), map(), Scope.t()) ::
          {:ok, map(), map(), [String.t()]} | {:error, term()}
  def put_squad(%AgentDesign{kind: :squad_edit} = design, attrs, user_scope) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    current = design.draft["squad"]["name"]
    names = Enum.reject([target_name(design), current], &is_nil/1)

    cond do
      elem(rights(design), 0) == :none ->
        {:error, :forbidden}

      Map.has_key?(attrs, "name") and not Enum.any?(names, &same?(&1, attrs["name"])) ->
        {:error,
         squad_changeset([
           {:name,
            {"squads cannot be renamed in a conversation; rename it on the squad's page", []}}
         ])}

      true ->
        attrs = Map.delete(attrs, "name")

        # A conflict goes when its field is written again, even with the
        # draft's own value (decision 8); `fields` are those that changed.
        given = Enum.filter(Changes.squad_fields(), &Map.has_key?(attrs, &1))

        with {:ok, draft, squad, fields} <-
               SquadDraft.put(design.draft, attrs, user_scope, fixed_name: true) do
          squad = put_conflicts(squad, List.wrap(squad["conflicts"]) -- given)
          {:ok, Map.put(draft, "squad", squad), squad, fields}
        end
    end
  end

  @doc """
  Restores one field of the draft to its baseline value (the page's
  「恢复为当前配置」): `part` `"agent"` (the `agent_edit` target) or
  `"squad"`. `{:ok, draft, edit}` (the pending edit) or `{:error,
  :not_a_field | :forbidden}`.
  """
  @spec revert(AgentDesign.t(), String.t(), String.t()) ::
          {:ok, map(), map() | nil} | {:error, :not_a_field | :forbidden}
  def revert(%AgentDesign{kind: :agent_edit} = design, "agent", field) do
    {rights, _owner} = rights(design)

    cond do
      rights == :none ->
        {:error, :forbidden}

      field not in Changes.agent_fields() or field in readonly(design, rights) ->
        {:error, :not_a_field}

      true ->
        [entry] = Draft.agents(design.draft)
        value = design.baseline["agent"][field]

        stored =
          entry
          |> Map.put(field, value)
          |> Map.put("updated_by", "user")
          |> put_conflicts(List.wrap(entry["conflicts"]) -- [field])

        edit = if entry[field] != value, do: %{"agent" => entry["name"], "fields" => [field]}
        {:ok, %{design.draft | "agents" => [stored]}, edit}
    end
  end

  def revert(%AgentDesign{kind: :squad_edit} = design, "squad", field) do
    cond do
      elem(rights(design), 0) == :none ->
        {:error, :forbidden}

      field not in Changes.squad_fields() ->
        {:error, :not_a_field}

      true ->
        squad = design.draft["squad"]
        value = design.baseline["squad"][field]

        stored =
          squad
          |> Map.put(field, value)
          |> Map.put("updated_by", "user")
          |> put_conflicts(List.wrap(squad["conflicts"]) -- [field])

        edit = if squad[field] != value, do: %{"squad" => true, "fields" => [field]}
        {:ok, Map.put(design.draft, "squad", stored), edit}
    end
  end

  def revert(_design, _part, _field), do: {:error, :not_a_field}

  ## Reading

  @doc "The changes of the draft of `design` against its baseline."
  @spec changes(AgentDesign.t()) :: [Changes.change()]
  def changes(%AgentDesign{kind: :agent_edit} = design),
    do: Changes.agent(design.baseline["agent"], List.first(Draft.agents(design.draft)))

  def changes(%AgentDesign{kind: :squad_edit} = design),
    do: Changes.squad(design.baseline["squad"], design.draft["squad"])

  @doc "The conflicting fields of `design` (after a rebaseline, until written again)."
  @spec conflicts(AgentDesign.t()) :: [String.t()]
  def conflicts(%AgentDesign{kind: :agent_edit} = design),
    do: List.wrap(List.first(Draft.agents(design.draft))["conflicts"])

  def conflicts(%AgentDesign{kind: :squad_edit} = design),
    do: List.wrap(design.draft["squad"]["conflicts"])

  @doc """
  What the user (the page) or the helper (`get_design`) sees of an edit
  conversation: `target` (`%{id, name, kind}`, the current name), the
  `baseline`, the `draft`, `changes`, `conflicts`, `readonly` and the
  user's `rights`. Someone other than the agent's owner sees provider
  accounts as `%{"name", "host"}` (in the baseline, draft and changes).
  """
  @spec present(AgentDesign.t(), keyword()) :: map()
  def present(%AgentDesign{} = design, _opts \\ []) do
    {rights, owner} = rights(design)
    target = Repo.one(from(a in Actor, where: a.id == ^design.target_actor_id))
    changes = changes(design)
    redact = design.kind == :agent_edit and rights != :owner

    %{
      target: target && %{id: target.id, name: target.name, kind: target.kind, owner: owner},
      baseline: if(redact, do: redact_baseline(design.baseline), else: design.baseline),
      draft: if(redact, do: redact_draft(design.draft), else: design.draft),
      changes: if(redact, do: Enum.map(changes, &redact_change/1), else: changes),
      conflicts: conflicts(design),
      readonly: readonly(design, rights),
      rights: rights
    }
  end

  @doc """
  A draft agent of `design` as the user may see it (a write's result):
  someone other than the owner of an `agent_edit` target gets its provider
  account as `%{"name", "host"}`, never its ID.
  """
  @spec shown_entry(AgentDesign.t(), map()) :: map()
  def shown_entry(%AgentDesign{kind: :agent_edit} = design, entry) do
    case rights(design) do
      {:owner, _name} -> entry
      _other -> redact_entry(entry)
    end
  end

  def shown_entry(_design, entry), do: entry

  defp redact_baseline(%{"agent" => agent} = baseline),
    do: %{baseline | "agent" => redact_entry(agent)}

  defp redact_draft(%{"agents" => agents} = draft),
    do: %{draft | "agents" => Enum.map(agents, &redact_entry/1)}

  defp redact_entry(entry) do
    entry
    |> Map.delete("provider_account_id")
    |> Map.put("provider_account", account(entry["provider_account_id"]))
  end

  defp redact_change(%{field: "provider_account_id"} = c),
    do: %{c | from: account(c.from), to: account(c.to)}

  defp redact_change(c), do: c

  defp account(nil), do: nil

  defp account(id) do
    case ProviderAccounts.summaries([id]) do
      %{^id => %{name: name, host: host}} -> %{"name" => name, "host" => host}
      _gone -> nil
    end
  end

  ## Helpers

  defp same?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same?(_a, _b), do: false

  defp error_changeset(errors),
    do: %Ecto.Changeset{data: %{}, types: Draft.types(), valid?: false, errors: errors}

  defp squad_changeset(errors),
    do: %Ecto.Changeset{data: %{}, types: %{name: :string}, valid?: false, errors: errors}
end

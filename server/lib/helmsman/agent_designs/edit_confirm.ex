defmodule Helmsman.AgentDesigns.EditConfirm do
  @moduledoc """
  Confirming an edit conversation (`add-edit-design-conversations`
  decisions 8, 9), in the conversation's write transaction (maintenance
  lock, the user's membership row, the conversation row `FOR UPDATE`).

  The target's rows are locked in the order of their own writes, then its
  draft fields are compared with the baseline before anything is written:

    * `agent_edit`: the identity and the profile `FOR UPDATE`
      (`Helmsman.Agents.lock_for_update/2`); the fields that differ from
      the baseline go to `Helmsman.Agents.update_locked/4` (the owner-only
      execution fields, queued runs moved, notifications).
    * `squad_edit`: the new agents are checked first; then the squad
      identity `FOR UPDATE` with the existing leader and members of the
      baseline and the draft `FOR SHARE`, the `squads` row `FOR UPDATE`
      (`Helmsman.Squads.lock_for_update/4`, never the `squads` row
      first); then the new agents are inserted and
      `Helmsman.Squads.write_locked/5` writes the fields that differ, with
      the current `lock_version`.

  Returns what the conversation must record: `{:rebaseline, baseline,
  draft, fields}` (the target changed since the baseline: nothing of it
  written), `{:applied, applied, created_actor_ids, result}`, or an error
  (`:no_changes`, `:not_found`, `:forbidden`, field errors).
  """

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.{AgentDesign, Changes, Draft, Edit}
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Squads

  @type outcome ::
          {:rebaseline, map(), map(), [String.t()]}
          | {:applied, [map()], [pos_integer()], map()}
          | {:error, term()}

  @doc "Confirms the locked edit conversation `design` as `scope`; see the module documentation."
  @spec run(Scope.t(), AgentDesign.t()) :: outcome()
  def run(%Scope{} = scope, %AgentDesign{kind: :agent_edit} = design) do
    with {:ok, actor, profile} <- Agents.lock_for_update(scope, design.target_actor_id),
         :ok <- active(profile),
         :ok <- Policy.authorize(scope, :administer_agent, actor) do
      baseline = design.baseline["agent"]
      current = Edit.agent_fields(actor, profile)

      case moved(baseline, current, Changes.agent_fields()) do
        [] -> apply_agent(scope, design, actor, profile)
        fields -> rebaseline_agent(design, current, fields)
      end
    end
  end

  def run(%Scope{} = scope, %AgentDesign{kind: :squad_edit} = design) do
    new_agents = Draft.agents(design.draft)

    with :ok <- validate_new(scope, new_agents) do
      locked =
        Squads.lock_for_update(
          scope.workspace.id,
          design.target_actor_id,
          Map.take(design.draft["squad"], ["leader", "members"]),
          names(design.baseline["squad"])
        )

      leader = Repo.get!(Actor, locked.squad.leader_agent_id)

      with :ok <- Policy.authorize(scope, :manage_squads, leader),
           do: compare_squad(scope, design, locked, new_agents)
    end
  end

  defp compare_squad(scope, design, locked, new_agents) do
    current = Edit.squad_baseline(design.target_actor_id)

    case moved(design.baseline["squad"], current["squad"], Changes.squad_fields()) do
      [] -> apply_squad(scope, design, locked, current, new_agents)
      fields -> rebaseline_squad(design, current, fields)
    end
  end

  defp active(nil), do: {:error, :not_found}
  defp active(%AgentProfile{archived_at: nil}), do: :ok
  defp active(_archived), do: {:error, :not_found}

  defp moved(baseline, current, fields),
    do: Enum.filter(fields, &(Map.get(baseline, &1) != Map.get(current, &1)))

  ## Rebaseline (decision 8): the target is not written

  # Unchanged draft fields follow the current value; a field both changed
  # to different values keeps the draft's and is a conflict. The
  # conflicts are recomputed from scratch.
  defp merge(old, current, entry, fields) do
    Enum.reduce(fields, {entry, []}, fn field, {entry, conflicts} ->
      draft = Map.get(entry, field)

      cond do
        draft == Map.get(old, field) ->
          {Map.put(entry, field, Map.get(current, field)), conflicts}

        draft == Map.get(current, field) ->
          {entry, conflicts}

        true ->
          {entry, [field | conflicts]}
      end
    end)
  end

  defp put_conflicts(entry, []), do: Map.delete(entry, "conflicts")
  defp put_conflicts(entry, conflicts), do: Map.put(entry, "conflicts", Enum.sort(conflicts))

  defp rebaseline_agent(design, current, fields) do
    [entry] = Draft.agents(design.draft)
    {entry, conflicts} = merge(design.baseline["agent"], current, entry, fields)
    entry = entry |> Map.put("name", current["name"]) |> put_conflicts(conflicts)

    {:rebaseline, %{"agent" => current}, %{design.draft | "agents" => [entry]}, fields}
  end

  defp rebaseline_squad(design, current, fields) do
    squad = design.draft["squad"]
    {squad, conflicts} = merge(design.baseline["squad"], current["squad"], squad, fields)
    squad = put_conflicts(squad, conflicts)
    {:rebaseline, current, Map.put(design.draft, "squad", squad), fields}
  end

  ## Writing

  defp apply_agent(scope, design, actor, profile) do
    [entry] = Draft.agents(design.draft)

    case Changes.agent(design.baseline["agent"], entry) do
      [] ->
        {:error, :no_changes}

      changes ->
        write_agent(scope, actor, profile, entry, changes)
    end
  end

  defp write_agent(scope, actor, profile, entry, changes) do
    attrs = Map.new(changes, &{&1.field, &1.to})

    with {:ok, attrs} <- reference_attrs(scope, attrs),
         {:ok, view} <- Agents.update_locked(scope, actor, profile, attrs) do
      {:applied, applied(changes), [], %{agents: [view], squad: nil}}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, {:invalid, %{entry["name"] => draft_errors(cs)}}}

      error ->
        error
    end
  end

  defp draft_errors(cs) do
    errors =
      Enum.map(cs.errors, fn {field, error} ->
        {if(field == :mcp_server_ids, do: :mcp_servers, else: field), error}
      end)

    %{cs | errors: errors}
  end

  defp reference_attrs(scope, %{"mcp_servers" => names} = attrs) do
    case Helmsman.McpServers.resolve_names(scope, names, lock: true) do
      {:ok, ids} ->
        {:ok, attrs |> Map.delete("mcp_servers") |> Map.put("mcp_server_ids", ids)}

      {:error, message} ->
        {:error,
         %Ecto.Changeset{
           data: %{},
           types: Draft.types(),
           valid?: false,
           errors: [{:mcp_servers, {message, []}}]
         }}
    end
  end

  defp reference_attrs(_scope, attrs), do: {:ok, attrs}

  defp apply_squad(scope, design, locked, current, new_agents) do
    changes = Changes.squad(design.baseline["squad"], design.draft["squad"])

    if changes == [] and new_agents == [],
      do: {:error, :no_changes},
      else: write_squad(scope, design, locked, current, new_agents, changes)
  end

  defp write_squad(scope, design, locked, current, new_agents, changes) do
    with {:ok, created} <- insert_new(scope, new_agents) do
      actors = Enum.map(created, &Repo.get!(Actor, &1.actor_id))
      name = Map.fetch!(locked.refs.locked, design.target_actor_id).name

      attrs =
        changes
        |> Map.new(&{&1.field, &1.to})
        |> Map.put("lock_version", current["lock_version"])

      scope
      |> Squads.write_locked(name, locked, attrs, actors)
      |> squad_result(changes, actors, created, name)
    end
  end

  defp squad_result({:ok, _}, changes, actors, created, name),
    do: {:applied, applied(changes), Enum.map(actors, & &1.id), %{agents: created, squad: name}}

  defp squad_result({:error, :forbidden}, _changes, _actors, _created, _name),
    do:
      {:error,
       {:invalid_squad, squad_changeset([{:leader, {"you may not make it the leader", []}}])}}

  defp squad_result({:error, %Ecto.Changeset{} = cs}, _changes, _actors, _created, _name),
    do: {:error, {:invalid_squad, cs}}

  defp squad_result(error, _changes, _actors, _created, _name), do: error

  defp validate_new(scope, agents) do
    errors =
      Enum.reduce(agents, %{}, fn entry, acc ->
        case Draft.validate_create(scope, entry) do
          :ok -> acc
          {:error, cs} -> Map.put(acc, entry["name"], cs)
        end
      end)

    if errors == %{}, do: :ok, else: {:error, {:invalid, errors}}
  end

  # A name taken since the check aborts the transaction: that agent's
  # errors are returned and everything rolls back.
  defp insert_new(scope, agents) do
    Enum.reduce_while(agents, {:ok, []}, fn entry, {:ok, created} ->
      result =
        with {:ok, attrs} <- Draft.create_attrs(entry, scope), do: Agents.insert_new(scope, attrs)

      case result do
        {:ok, view} -> {:cont, {:ok, created ++ [view]}}
        {:error, cs} -> {:halt, {:error, {:invalid, %{entry["name"] => AgentProfile.scrub(cs)}}}}
      end
    end)
  end

  defp names(squad) do
    [squad["leader"] | Enum.map(List.wrap(squad["members"]), & &1["name"])]
    |> Enum.filter(&is_binary/1)
  end

  # What the conversation keeps (decision 13): field, old and new value.
  defp applied(changes),
    do: Enum.map(changes, &%{"field" => &1.field, "from" => &1.from, "to" => &1.to})

  defp squad_changeset(errors),
    do: %Ecto.Changeset{data: %{}, types: %{leader: :string}, valid?: false, errors: errors}

  @doc """
  The structured log line of a confirm (decision 13): workspace, user,
  kind, target and the field names, never the values.
  """
  @spec log(AgentDesign.t(), [map()], [pos_integer()]) :: :ok
  def log(%AgentDesign{} = design, applied, created) do
    Logger.info(
      "design_confirmed workspace=#{design.workspace_id} user=#{design.user_id} " <>
        "kind=#{design.kind} target=#{design.target_actor_id} " <>
        "fields=#{Enum.map_join(applied, ",", & &1["field"])} created=#{length(created)}"
    )
  end
end

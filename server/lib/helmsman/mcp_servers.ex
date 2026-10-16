defmodule Helmsman.McpServers do
  @moduledoc "Personal encrypted MCP definitions and references owned by the same user as their agents."
  import Ecto.Query
  require Logger
  alias Helmsman.{Events, Policy, Repo, Tx}

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.McpServers.{Definition, Entry, Ref, Summary}
  alias Helmsman.Workspaces.Workspace

  @doc "Names and type only, for the user's design conversation; no executable parameters."
  def design_options(user_id) do
    Repo.all(
      from d in Definition,
        where: d.user_id == ^user_id,
        order_by: d.name,
        select: d
    )
    |> Enum.map(fn d -> %{id: d.id, name: d.name, type: d.type, program: program(d.config)} end)
  end

  defp program(%{"command" => command}) when is_binary(command),
    do: Summary.mask(Path.basename(command))

  defp program(%{"url" => url}) when is_binary(url), do: URI.parse(url).host
  defp program(_), do: nil

  def resolve_names(scope, names) when is_list(names) do
    options = design_options(scope.user.id)
    by_name = Map.new(options, &{String.downcase(&1.name), &1.id})
    ids = Enum.map(names, fn name -> if is_binary(name), do: by_name[String.downcase(name)] end)

    if length(names) <= 16 and Enum.all?(ids, &is_integer/1) and
         length(Enum.uniq(ids)) == length(ids),
       do: {:ok, ids},
       else:
         {:error,
          "definition missing or renamed; available definitions: " <>
            Enum.map_join(options, ", ", & &1.name)}
  end

  def resolve_names(scope, _), do: resolve_names(scope, [nil])

  def list(scope) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers) do
      {:ok,
       Repo.all(from d in Definition, where: d.user_id == ^scope.user.id, order_by: d.name)
       |> Enum.map(&view/1)}
    end
  end

  def get(scope, id) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers),
         %Definition{} = d <- own(scope, id) do
      {:ok, view(d)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def create(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers) do
      Tx.run(fn -> create_locked(scope, attrs) end)
      |> scrub()
    end
  end

  defp create_locked(scope, attrs) do
    Repo.one!(from u in User, where: u.id == ^scope.user.id, lock: "FOR UPDATE", select: u.id)
    count = Repo.aggregate(from(d in Definition, where: d.user_id == ^scope.user.id), :count)
    if count >= 32, do: {:error, :limit_reached}, else: insert_definition(scope, attrs)
  end

  defp insert_definition(scope, attrs) do
    with {:ok, d} <-
           %Definition{user_id: scope.user.id}
           |> Definition.changeset(attrs)
           |> Repo.insert(log: false) do
      notify(d, :created)
      {:ok, view(d)}
    end
  end

  def update(scope, id, attrs) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers) do
      Tx.run(fn -> update_locked(own(scope, id, true), attrs) end)
      |> scrub()
    end
  end

  defp update_locked(nil, _), do: {:error, :not_found}

  defp update_locked(d, attrs) do
    cs = d |> Definition.changeset(attrs) |> rename_conflicts(d)

    with {:ok, updated} <-
           cs |> Ecto.Changeset.optimistic_lock(:lock_version) |> Repo.update(log: false) do
      notify(updated, :updated)
      {:ok, view(updated)}
    end
  end

  def delete(scope, id) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers) do
      Tx.run(fn -> delete_locked(own(scope, id, true)) end)
    end
  end

  defp delete_locked(nil), do: {:error, :not_found}

  defp delete_locked(d) do
    case agents(d.id) do
      [] ->
        Repo.delete!(d, log: false)
        notify(d, :deleted)
        {:ok, :deleted}

      used ->
        {:error, {:in_use, used}}
    end
  end

  def editable(scope, id) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers),
         %Definition{} = d <- own(scope, id) do
      {:ok, Entry.editable(%{d.name => d.config})[d.name]}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def references(actor_ids) do
    Repo.all(
      from r in Ref,
        join: d in Definition,
        on: d.id == r.server_id,
        where: r.agent_actor_id in ^actor_ids,
        order_by: [r.agent_actor_id, r.position],
        select: {r.agent_actor_id, %{id: d.id, name: d.name, type: d.type, source: "personal"}}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def validate_refs(cs, actor) do
    case Ecto.Changeset.fetch_change(cs, :mcp_server_ids) do
      :error ->
        if Ecto.Changeset.changed?(cs, :extra_mcp_servers) and actor.id do
          ids = Repo.all(from r in Ref, where: r.agent_actor_id == ^actor.id, select: r.server_id)
          validate_refs(Ecto.Changeset.put_change(cs, :mcp_server_ids, ids), actor)
        else
          cs
        end

      {:ok, ids} ->
        validate_ref_ids(cs, actor, ids)
    end
  end

  defp validate_ref_ids(cs, actor, ids) do
    definitions =
      Repo.all(
        from d in Definition,
          where: d.id in ^ids and d.user_id == ^actor.owner_id,
          order_by: d.id,
          lock: "FOR SHARE"
      )

    own_names =
      (Ecto.Changeset.get_field(cs, :extra_mcp_servers) || %{})
      |> Map.keys()
      |> MapSet.new(&String.downcase/1)

    cond do
      length(ids) > 16 ->
        Ecto.Changeset.add_error(cs, :mcp_server_ids, "must contain at most 16 definitions")

      length(ids) != length(definitions) ->
        Ecto.Changeset.add_error(
          cs,
          :mcp_server_ids,
          "definition does not exist or belongs to another user"
        )

      Enum.any?(definitions, &MapSet.member?(own_names, String.downcase(&1.name))) ->
        Ecto.Changeset.add_error(
          cs,
          :mcp_server_ids,
          "conflicts with this agent's own server"
        )

      true ->
        cs
    end
  end

  def save_refs(actor, ids) do
    Repo.delete_all(from r in Ref, where: r.agent_actor_id == ^actor.id)

    entries =
      Enum.with_index(Enum.uniq(ids), fn id, position ->
        %{
          agent_actor_id: actor.id,
          workspace_id: actor.workspace_id,
          server_id: id,
          position: position
        }
      end)

    Repo.insert_all(Ref, entries)
    :ok
  end

  def effective(profile) do
    effective_many([profile])[profile.actor_id]
  end

  def effective_many(profiles) do
    actor_ids = Enum.map(profiles, & &1.actor_id)

    definitions =
      Repo.all(
        from r in Ref,
          join: d in Definition,
          on: d.id == r.server_id,
          where: r.agent_actor_id in ^actor_ids,
          order_by: [r.agent_actor_id, r.position],
          select: {r.agent_actor_id, d}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(profiles, fn profile ->
      {profile.actor_id, merge_definitions(profile, Map.get(definitions, profile.actor_id, []))}
    end)
  end

  defp merge_definitions(profile, definitions) do
    own = profile.extra_mcp_servers || %{}
    folded = MapSet.new(Map.keys(own), &String.downcase/1)

    Enum.reduce(definitions, {own, []}, fn d, {config, warnings} ->
      if MapSet.member?(folded, String.downcase(d.name)) do
        {config, warnings ++ ["MCP 服务器 #{d.name} 的个人定义被 Agent 自有配置覆盖"]}
      else
        {Map.put(config, d.name, d.config), warnings}
      end
    end)
  end

  def agent_editable(scope, actor) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers),
         :ok <- Policy.authorize(scope, :configure_agent, actor),
         true <- scope.user.id == actor.owner_id do
      profile = Repo.get_by!(AgentProfile, actor_id: actor.id)
      {:ok, Entry.editable(profile.extra_mcp_servers)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def agent_summaries(scope, actor) do
    with :ok <- Policy.authorize(scope, :view_agents),
         true <- actor.workspace_id == scope.workspace.id do
      profile = Repo.get_by(AgentProfile, actor_id: actor.id)

      if profile do
        {config, _} = effective(profile)
        refs = references([actor.id])[actor.id] || []
        own_names = MapSet.new(Map.keys(profile.extra_mcp_servers || %{}), &String.downcase/1)
        names = MapSet.new(refs, & &1.name)

        detailed? =
          scope.user && (scope.user.id == actor.owner_id or scope.role in [:owner, :admin])

        summaries =
          config
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&entry_summary(&1, names, own_names, detailed?))

        shadowed = shadowed_summaries(refs, own_names, detailed?)

        {:ok, summaries ++ shadowed}
      else
        {:ok, []}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp entry_summary({name, entry}, names, own_names, detailed?) do
    source =
      if MapSet.member?(names, name) and not MapSet.member?(own_names, String.downcase(name)),
        do: "personal",
        else: "agent"

    if detailed?, do: Summary.of(name, entry, source), else: %{name: name, source: source}
  end

  defp shadowed_summaries(_refs, _own_names, false), do: []

  defp shadowed_summaries(refs, own_names, _) do
    refs
    |> Enum.filter(&MapSet.member?(own_names, String.downcase(&1.name)))
    |> Enum.map(&%{name: &1.name, source: "personal", shadowed: true})
  end

  defp own(scope, id, lock? \\ false) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) ->
        query = from d in Definition, where: d.user_id == ^scope.user.id and d.id == ^id
        Repo.one(if lock?, do: lock(query, "FOR UPDATE"), else: query)

      _ ->
        nil
    end
  end

  defp view(d),
    do: %{
      id: d.id,
      name: d.name,
      type: d.type,
      summary: Summary.of(d.name, d.config, "personal"),
      agents: agents(d.id),
      lock_version: d.lock_version,
      updated_at: d.updated_at
    }

  defp agents(id, include_archived? \\ false) do
    Repo.all(
      from r in Ref,
        join: a in Actor,
        on: a.id == r.agent_actor_id,
        join: p in AgentProfile,
        on: p.actor_id == a.id,
        join: w in Workspace,
        on: w.id == a.workspace_id,
        where: r.server_id == ^id and (^include_archived? or is_nil(p.archived_at)),
        order_by: [w.slug, a.name],
        select: %{actor_id: a.id, workspace_slug: w.slug, name: a.name}
    )
  end

  defp rename_conflicts(cs, d) do
    name = Ecto.Changeset.get_field(cs, :name)

    conflicts =
      if is_binary(name) and String.downcase(name) != String.downcase(d.name) do
        Enum.filter(agents(d.id, true), fn a ->
          profile = Repo.get_by!(AgentProfile, actor_id: a.actor_id)
          own = Map.keys(profile.extra_mcp_servers || %{})

          other =
            (references([a.actor_id])[a.actor_id] || [])
            |> Enum.reject(&(&1.id == d.id))
            |> Enum.map(& &1.name)

          Enum.any?(own ++ other, &(String.downcase(&1) == String.downcase(name)))
        end)
      else
        []
      end

    if conflicts == [],
      do: cs,
      else:
        Ecto.Changeset.add_error(cs, :name, "conflicts with agents: %{agents}",
          agents: Enum.map_join(conflicts, ", ", & &1.name)
        )
  end

  defp notify(d, action) do
    Events.after_commit("user_mcp_servers:#{d.user_id}", {:mcp_servers_changed})

    Tx.after_commit(fn ->
      Logger.info("MCP definition changed",
        user_id: d.user_id,
        server_name: d.name,
        action: action
      )
    end)

    Enum.each(agents(d.id), fn a ->
      actor = Repo.get!(Actor, a.actor_id)
      Events.after_commit(Events.topic(:workspace, actor.workspace_id), {:agents_changed})
    end)
  end

  defp scrub({:error, %Ecto.Changeset{} = cs}), do: {:error, Definition.scrub(cs)}
  defp scrub(other), do: other
end

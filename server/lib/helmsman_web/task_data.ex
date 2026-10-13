defmodule HelmsmanWeb.TaskData do
  @moduledoc """
  Reads of the task pages beyond plain `Helmsman.Tasks.get/2` (design D11): assignable
  identities, a project's labels and one keyset page of the task list.

  Paging uses the `:before` cursor of `Helmsman.Tasks.list/3` (`{updated_at, id}` of
  the last row shown), not an offset: a task that changes moves before the cursor and
  reaches the page through its notification, so live updates neither skip nor repeat
  rows when 加载更多 continues (design D5).
  """

  alias Helmsman.{Actors, Agents, Tasks}
  alias HelmsmanWeb.{RunComponents, SquadComponents, SquadData}

  @page_size 50

  @doc "Rows per 加载更多 page."
  def page_size, do: @page_size

  @doc """
  Identities a task may be assigned to (humans first, then agents, by name), as maps
  for `actor_chip`: `%{name, kind, owner_name}`, agents also with `managed?` (from
  `agents`, see `agent_info/1`).
  """
  @spec assignable(map(), %{String.t() => map()} | nil) :: [map()]
  def assignable(scope, agents \\ nil) do
    case Actors.list_assignable(scope) do
      {:ok, actors} ->
        agents = agents || agent_info(scope)
        Enum.map(actors, &actor_view(&1, agents))

      {:error, _} ->
        []
    end
  end

  @doc """
  The squads of the assignee menu and its confirmation (add-squads-autopilots-ui D6),
  merged into `availability` (`HelmsmanWeb.RunData.availability/1`, by agent name):
  `%{name => %{kind: :squad, leader, result: :ok | {:skipped, reason}, refused, runtime}}`
  for every enabled squad, `runtime` being the leader's (for the offline note).
  """
  @spec with_squads(map(), %{String.t() => map()}) :: %{String.t() => map()}
  def with_squads(scope, availability) do
    case SquadData.list(scope) do
      {:ok, squads} ->
        squad_availability = SquadData.availability(scope)

        for %{disabled: false} = squad <- squads, into: availability do
          entry = squad_availability[squad.name]

          {squad.name,
           %{
             kind: :squad,
             leader: squad.leader.name,
             result: squad_result(entry),
             refused: SquadComponents.refused(entry),
             runtime: get_in(availability, [squad.leader.name, :runtime])
           }}
        end

      _ ->
        availability
    end
  end

  @doc """
  Why `name` cannot be dispatched, from its `availability` entry (agent or squad, see
  `with_squads/2`); nil when it can.
  """
  def unavailable_text(_name, %{result: :ok}), do: nil

  def unavailable_text(name, %{kind: :squad, result: {:skipped, reason}} = entry),
    do: SquadComponents.unavailable_reason(name, {:skipped, reason, entry.refused})

  def unavailable_text(name, %{result: result}),
    do: RunComponents.unavailable_reason(name, result)

  def unavailable_text(_name, _entry), do: nil

  defp squad_result({:skipped, reason, _refused}), do: {:skipped, reason}
  defp squad_result(_ok), do: :ok

  defp actor_view(actor, agents) do
    owner = actor.owner && (actor.owner.display_name || actor.owner.email)
    view = %{name: actor.name, kind: to_string(actor.kind), owner_name: owner}

    case agents[actor.name] do
      %{managed?: managed?} when actor.kind == :agent -> Map.put(view, :managed?, managed?)
      _ -> view
    end
  end

  @doc """
  The workspace's agents (archived and disabled included) by name, as the extra
  fields of their `actor_chip`: `%{managed?}` plus `owner_name` when the owner has a
  display name; squads (disabled included) with their `state`. Task summaries refer to actors by `%{name, kind}` only.
  """
  @spec agent_info(map()) :: %{String.t() => map()}
  def agent_info(scope) do
    agents =
      case Agents.list(scope) do
        {:ok, views} -> Map.new(views, &{&1.name, agent_fields(&1)})
        {:error, _} -> %{}
      end

    Map.merge(squad_info(scope), agents)
  end

  # Squads by name with their state, so an assigned squad that was disabled shows it
  # (add-squads-autopilots-ui D5, code-review-1 P2-3).
  defp squad_info(scope) do
    case SquadData.list(scope) do
      {:ok, squads} ->
        Map.new(squads, &{&1.name, %{state: if(&1.disabled, do: :disabled, else: :active)}})

      _ ->
        %{}
    end
  end

  defp agent_fields(%{kind: kind, owner: owner}) do
    fields = %{managed?: kind == "managed"}
    if owner[:name], do: Map.put(fields, :owner_name, owner.name), else: fields
  end

  @doc "Labels used by the tasks of the project with `key`, sorted."
  @spec labels(map(), String.t()) :: [String.t()]
  def labels(scope, key) do
    case Tasks.list_labels(scope, key) do
      {:ok, labels} -> labels
      {:error, _} -> []
    end
  end

  @doc """
  One page of the task list after `cursor` (`nil` for the first page):
  `{:ok, rows, has_more?, cursor}`, `cursor` being `{updated_at, id}` of the last row
  returned (the previous cursor when the page is empty).
  """
  @spec page(map(), String.t(), keyword(), {DateTime.t(), pos_integer()} | nil) ::
          {:ok, [Tasks.Task.t()], boolean(), {DateTime.t(), pos_integer()} | nil}
          | {:error, term()}
  def page(scope, key, opts, cursor) do
    opts = Keyword.merge(opts, limit: @page_size + 1, before: cursor)

    with {:ok, tasks} <- Tasks.list(scope, key, opts) do
      rows = Enum.take(tasks, @page_size)

      cursor =
        case List.last(rows) do
          nil -> cursor
          last -> {last.updated_at, last.id}
        end

      {:ok, rows, length(tasks) > @page_size, cursor}
    end
  end
end

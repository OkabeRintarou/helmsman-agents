defmodule Helmsman.Runs.Triggers do
  @moduledoc """
  Rules on the trigger entries of a run (`runs.triggers`).

  Neutral markers say nothing about why a run exists and are left out by
  every rule: automatic retries (`retry` with `auto: true`) and
  `unblocked` (`add-dependency-dispatch` decision 3).
  """

  @assignment_kinds ~w(assign reopen resubmit)

  @typedoc """
  What a trigger is bound to (`bound_assignee/2`): an identity, or the
  squad (by `squads.id`) whose identity it is.
  """
  @type bound :: {:actor, pos_integer()} | {:squad, pos_integer()} | nil

  @doc """
  The assignee a trigger of the run `run` (`agent_id`, `squad_id`) exists
  for (`add-squads` decision 10), nil when it does not depend on the
  assignee:

    * `assign`, `reopen`, `resubmit`, `delegate_done`, `spec_reviewed`,
      `spec_decided` (`add-spec-workflow` decision 11), `epic_stalled`
      (`improve-squad-leader-orchestration` decision 10): the squad in a run
      as a squad leader, otherwise the run's agent;
    * `delegated`: the squad of the entry (`"squad_id"`);
    * `answer`: the entry's `"bound_assignee_id"`; an older entry with only
      `"assignee_bound" => true` is bound to the run's agent;
    * anything else (manual, mention, callbacks, steering fallbacks,
      retries, `unblocked`): nil.
  """
  @spec bound_assignee(map(), %{
          required(:agent_id) => pos_integer(),
          required(:squad_id) => pos_integer() | nil,
          optional(any()) => any()
        }) :: bound()
  def bound_assignee(%{"kind" => kind}, %{squad_id: squad_id, agent_id: agent_id})
      when kind in [
             "assign",
             "reopen",
             "resubmit",
             "delegate_done",
             "spec_reviewed",
             "spec_decided",
             "epic_stalled"
           ] do
    if squad_id, do: {:squad, squad_id}, else: {:actor, agent_id}
  end

  def bound_assignee(%{"kind" => "delegated", "squad_id" => squad_id}, _run)
      when is_integer(squad_id),
      do: {:squad, squad_id}

  def bound_assignee(%{"kind" => "answer", "bound_assignee_id" => id}, _run) when is_integer(id),
    do: {:actor, id}

  def bound_assignee(%{"kind" => "answer", "assignee_bound" => true} = trigger, %{agent_id: id})
      when not is_map_key(trigger, "bound_assignee_id"),
      do: {:actor, id}

  def bound_assignee(_trigger, _run), do: nil

  @doc """
  The single assignee every trigger of `run` that is not a neutral marker
  is bound to (`bound_assignee/2`), or nil: no such trigger, one not bound,
  or two bound to different assignees. What an `answer` to a question
  written in `run` is bound to (decision 10).
  """
  @spec run_bound(%{
          required(:triggers) => [map()],
          required(:agent_id) => pos_integer(),
          required(:squad_id) => pos_integer() | nil,
          optional(any()) => any()
        }) :: bound()
  def run_bound(%{triggers: triggers} = run) do
    case triggers
         |> Enum.reject(&neutral?/1)
         |> Enum.map(&bound_assignee(&1, run))
         |> Enum.uniq() do
      [{_, _} = bound] -> bound
      _other -> nil
    end
  end

  @doc """
  Whether a run with `triggers` waits for its task's dependencies
  (`add-dependency-dispatch` decision 3): neutral markers are left out;
  what is left is not empty and every entry is `assign`, `reopen` or
  `resubmit`. `dependency_gated_sql/1` is the same rule in SQL.
  """
  @spec dependency_gated?([map()]) :: boolean()
  def dependency_gated?(triggers) when is_list(triggers) do
    case Enum.reject(triggers, &neutral?/1) do
      [] -> false
      kept -> Enum.all?(kept, &assignment?/1)
    end
  end

  @neutral_sql "(e->>'kind' = 'unblocked' OR (e->>'kind' = 'retry' AND e->'auto' = 'true'::jsonb))"

  @dependency_gated_sql "(EXISTS (SELECT 1 FROM jsonb_array_elements(?) e WHERE NOT #{@neutral_sql})" <>
                          " AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(?) e WHERE NOT #{@neutral_sql}" <>
                          " AND e->>'kind' NOT IN ('assign', 'reopen', 'resubmit')))"

  @doc "`dependency_gated?/1` on the `triggers` column, inside a query."
  defmacro dependency_gated_sql(triggers) do
    sql = @dependency_gated_sql

    quote do
      fragment(unquote(sql), unquote(triggers), unquote(triggers))
    end
  end

  @doc """
  Whether `trigger` is a neutral marker: an automatic retry or `unblocked`.
  """
  @spec neutral?(map()) :: boolean()
  def neutral?(%{"kind" => "retry", "auto" => true}), do: true
  def neutral?(%{"kind" => "unblocked"}), do: true
  def neutral?(_trigger), do: false

  defp assignment?(%{"kind" => kind}) when kind in @assignment_kinds, do: true
  defp assignment?(_trigger), do: false
end

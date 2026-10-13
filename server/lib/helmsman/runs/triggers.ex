defmodule Helmsman.Runs.Triggers do
  @moduledoc """
  Rules on the trigger entries of a run (`runs.triggers`).

  Neutral markers say nothing about why a run exists and are left out by
  every rule: automatic retries (`retry` with `auto: true`) and
  `unblocked` (`add-dependency-dispatch` decision 3).
  """

  @assignment_kinds ~w(assign reopen resubmit)

  @doc """
  Whether a run with `triggers` runs only because of its task's assignee
  (`add-continuation-triggers` decision 8): neutral markers are left out;
  what is left is not empty and every entry is an assignment (`assign`,
  `reopen`, `resubmit`) or an `answer` recorded with `assignee_bound: true`.
  A `steer` is not (`add-run-steering` decision 5).

  Used when a run is claimed or started (an assignee change makes such a
  run obsolete) and when an `answer` is enqueued.
  """
  @spec assignee_bound?([map()]) :: boolean()
  def assignee_bound?(triggers) when is_list(triggers) do
    case Enum.reject(triggers, &neutral?/1) do
      [] -> false
      kept -> Enum.all?(kept, &assignee_trigger?/1)
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

  defp assignee_trigger?(%{"kind" => "answer", "assignee_bound" => true}), do: true
  defp assignee_trigger?(trigger), do: assignment?(trigger)
end

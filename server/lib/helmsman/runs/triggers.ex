defmodule Helmsman.Runs.Triggers do
  @moduledoc """
  Rules on the trigger entries of a run (`runs.triggers`).
  """

  @assignment_kinds ~w(assign reopen resubmit unblocked)

  @doc """
  Whether a run with `triggers` runs only because of its task's assignee
  (`add-continuation-triggers` decision 8): automatic retry markers
  (`retry` with `auto: true`) are left out; what is left is not empty and
  every entry is an assignment (`assign`, `reopen`, `resubmit`,
  `unblocked`) or an `answer` recorded with `assignee_bound: true`.

  Used when a run is claimed or started (an assignee change makes such a
  run obsolete) and when an `answer` is enqueued.
  """
  @spec assignee_bound?([map()]) :: boolean()
  def assignee_bound?(triggers) when is_list(triggers) do
    case Enum.reject(triggers, &auto_retry?/1) do
      [] -> false
      kept -> Enum.all?(kept, &assignment?/1)
    end
  end

  defp auto_retry?(%{"kind" => "retry", "auto" => true}), do: true
  defp auto_retry?(_trigger), do: false

  defp assignment?(%{"kind" => kind}) when kind in @assignment_kinds, do: true
  defp assignment?(%{"kind" => "answer", "assignee_bound" => true}), do: true
  defp assignment?(_trigger), do: false
end

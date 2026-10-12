defmodule HelmsmanWeb.TaskLive.Filter do
  @moduledoc """
  The task list's filters (design D5): URL schema, domain options for
  `Helmsman.Tasks.list/3`, quick views, and `match?/2` deciding whether a task summary
  from a notification belongs in the current list (same meaning as the domain query).
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  @statuses ~w(new in_progress done verified rejected cancelled)
  @open ~w(new in_progress done)
  @closed ~w(verified rejected cancelled)

  @doc "The `HelmsmanWeb.Filters` schema of the task list."
  def schema, do: [status: {:list, @statuses}, label: :string, assignee: :string]

  @doc "Statuses in display order."
  def statuses, do: @statuses

  @doc "Options for `Helmsman.Tasks.list/3`; `assignee=@none` means unassigned."
  @spec domain_opts(map()) :: keyword()
  def domain_opts(filters) do
    [
      status: filters[:status],
      label: filters[:label],
      assignee: if(filters[:assignee] == "@none", do: "", else: filters[:assignee])
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Quick views: `[{id, label, statuses | nil}]`."
  def views do
    [
      {:all, dgettext("ui", "全部"), nil},
      {:open, dgettext("ui", "未完成"), @open},
      {:closed, dgettext("ui", "已结束"), @closed}
    ]
  end

  @doc "The quick view whose status set equals the filter's, or nil."
  def current_view(filters) do
    statuses = filters[:status] && MapSet.new(filters[:status])

    Enum.find_value(views(), fn {id, _label, view_statuses} ->
      if view_statuses == nil,
        do: statuses == nil && id,
        else: statuses == MapSet.new(view_statuses) && id
    end)
  end

  @doc "The filters of a quick view, keeping label and assignee."
  def apply_view(filters, nil), do: Map.delete(filters, :status)
  def apply_view(filters, statuses), do: Map.put(filters, :status, statuses)

  @doc "Whether the task `summary` passes `filters`."
  @spec match?(map(), map()) :: boolean()
  def match?(summary, filters) do
    status?(summary, filters[:status]) and label?(summary, filters[:label]) and
      assignee?(summary, filters[:assignee])
  end

  defp status?(_summary, nil), do: true
  defp status?(summary, statuses), do: to_string(summary.status) in statuses

  defp label?(_summary, nil), do: true

  defp label?(summary, label),
    do: (label |> String.trim() |> String.downcase()) in (summary.labels || [])

  defp assignee?(_summary, nil), do: true
  defp assignee?(summary, "@none"), do: summary.assignee == nil
  defp assignee?(%{assignee: nil}, _name), do: false

  defp assignee?(%{assignee: %{name: name}}, filter),
    do: String.downcase(name) == String.downcase(filter)
end

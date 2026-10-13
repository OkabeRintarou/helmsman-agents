defmodule Helmsman.BQL.Fields do
  @moduledoc "The fixed BQL field and operator catalogue."
  @equality [:eq, :neq, :in, :not_in]
  @substring [:match, :nmatch]
  @ordered [:gt, :gte, :lt, :lte]
  @empty [:empty, :not_empty]
  @definitions [
    {:project, ["key"], @equality, :name, true},
    {:id, [], @equality ++ @substring, :task_id, true},
    {:status, [], @equality, :status, true},
    {:priority, [], @equality ++ @ordered, ["low", "medium", "high"], true},
    {:labels, ["label"], @equality ++ @substring ++ @empty, :name, false},
    {:created_by, ["creator", "reporter", "requester"], @equality ++ @substring, :identity, true},
    {:assignee, [], @equality ++ @substring ++ @empty, :identity, true},
    {:kind, ["type"], @equality, ["task", "epic"], true},
    {:epic, ["parent"], @equality ++ @empty, :task_id, false},
    {:blocked, [], [:eq, :neq], :boolean, false},
    {:depends_on, [], @equality ++ @empty, :task_id, false},
    {:blocks, [], @equality ++ @empty, :task_id, false},
    {:replaces, [], @equality ++ @empty, :task_id, false},
    {:replaced_by, [], @equality ++ @empty, :task_id, false},
    {:title, [], [:eq, :neq] ++ @substring, :text, true},
    {:description, [], @substring ++ @empty, :text, false},
    {:text, [], @substring, :text, false},
    {:feedback, [], @substring ++ @empty, :text, false},
    {:created, [], @ordered, :date, true},
    {:updated, [], @ordered, :date, true},
    {:question, ["open_question"], [:eq, :neq], :boolean, true},
    {:feedback_count, [], [:eq, :neq] ++ @ordered, :integer, true},
    {:assignee_kind, [], @equality, ["human", "agent", "squad", "system"], false},
    {:created_by_kind, [], @equality, ["human", "agent", "squad", "system"], false},
    {:owner, [], @equality, :identity, false},
    {:squad, [], @equality, :name, false},
    {:run, [], @equality ++ @empty,
     [
       "deferred",
       "queued",
       "claimed",
       "running",
       "cancelling",
       "succeeded",
       "failed",
       "cancelled"
     ], true},
    {:pr, [], @equality ++ @empty, ["draft", "open", "merged", "closed"], true},
    {:ci, [], @equality ++ @empty, ["pending", "success", "failure"], false},
    {:merge, [], @equality ++ @empty, ["waiting", "stale", "merged", "blocked", "failed"], false}
  ]
  @symbols %{
    eq: "=",
    neq: "!=",
    match: "~",
    nmatch: "!~",
    gt: ">",
    gte: ">=",
    lt: "<",
    lte: "<=",
    in: "IN",
    not_in: "NOT IN",
    empty: "IS EMPTY",
    not_empty: "IS NOT EMPTY"
  }
  def all do
    Enum.map(@definitions, fn {name, aliases, operators, values, sortable} ->
      %{name: name, aliases: aliases, operators: operators, values: values, sortable: sortable}
    end)
  end

  def fetch(name), do: Enum.find(all(), &(to_string(&1.name) == name or name in &1.aliases))
  def symbol(op), do: Map.fetch!(@symbols, op)
end

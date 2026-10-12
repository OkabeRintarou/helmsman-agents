defmodule Helmsman.Dispatch.Mentions do
  @moduledoc """
  Mention triggers (`add-continuation-triggers` decision 4, `mention`
  row): a feedback record that mentions a managed agent starts a `reply`
  run of it, a new initiation on behalf of the writer. A revision only
  counts the mentions the old record did not have. The author itself and
  the system identity never trigger; people and external agents are only
  marked.
  """

  alias Helmsman.Feedback.Entry
  alias Helmsman.Feedback.Mentions, as: Parse

  @doc "The identities `content` mentions in the workspace (`Helmsman.Feedback.Mentions`)."
  @spec resolve(pos_integer(), String.t() | nil) :: [pos_integer()]
  def resolve(_workspace_id, nil), do: []
  def resolve(workspace_id, content), do: Parse.resolve(workspace_id, Parse.extract(content))

  @doc """
  The agents to trigger: the `mentions` of the new record not in the old
  one (`nil` for a new record), without the author, among `agent_ids`,
  by actor ID.
  """
  @spec targets([pos_integer()], Entry.t() | nil, pos_integer(), MapSet.t()) :: [pos_integer()]
  def targets(mentions, old, author_id, agent_ids) do
    old_mentions = if old, do: old.mentions, else: []

    (mentions -- old_mentions)
    |> Enum.reject(&(&1 == author_id))
    |> Enum.filter(&MapSet.member?(agent_ids, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end
end

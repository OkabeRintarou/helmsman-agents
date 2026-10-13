defmodule Helmsman.AgentDesigns.AgentDesign do
  @moduledoc """
  A creation conversation (`add-agent-conversation` decision 3): a user
  talks with a managed agent (the helper) in turns, each turn a design run
  (`current_run_id` while it is not settled), and gets a draft of up to 8
  agents that only the user can confirm.

  `draft` is `%{"agents" => [entry]}` in the order the agents were added
  (`Helmsman.AgentDesigns.Draft`); `pending_edits` the user's changes not
  yet told to the helper (decision 16).
  """

  use Ecto.Schema

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces.Workspace

  @type status :: :open | :confirmed | :discarded | :expired
  @type t :: %__MODULE__{}

  @statuses [:open, :confirmed, :discarded, :expired]

  schema "agent_designs" do
    belongs_to :workspace, Workspace
    belongs_to :user, User
    belongs_to :helper_agent, Actor
    field :kind, Ecto.Enum, values: [:agent], default: :agent
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :draft, :map, default: %{"agents" => []}
    field :draft_version, :integer, default: 0
    field :pending_edits, {:array, :map}, default: []
    belongs_to :current_run, Run
    field :user_messages, :integer, default: 0
    field :created_actor_ids, {:array, :integer}, default: []
    field :last_activity_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end

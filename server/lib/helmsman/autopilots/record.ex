defmodule Helmsman.Autopilots.Record do
  @moduledoc """
  One trigger of an autopilot (`autopilot_runs`, `add-autopilots`
  decision 1): its source, the authorization source of this trigger, the
  execution configuration frozen when it was accepted (`config`, string
  keys: `name`, `mode`, `agent_id`, `project_id`, `instructions`,
  `title_template`, `timezone`, `create_tasks`), what it started (a task,
  a run) and how it ended (`status`, `reason`, `result`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @sources [:schedule, :manual, :webhook]
  @statuses [:pending, :skipped, :started, :succeeded, :failed, :cancelled]

  schema "autopilot_runs" do
    field :workspace_id, :id
    field :autopilot_id, :id
    field :source, Ecto.Enum, values: @sources
    field :scheduled_for, :utc_datetime_usec
    field :delivery_id, :string
    field :initiator_user_id, :id
    field :note, :string
    field :payload, Helmsman.Autopilots.Json
    field :config, :map
    field :task_id, :id
    field :run_id, :id
    field :status, Ecto.Enum, values: @statuses
    field :reason, :string
    field :result, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The sources of a trigger."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "Every status."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end

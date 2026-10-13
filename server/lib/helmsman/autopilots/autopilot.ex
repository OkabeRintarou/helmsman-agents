defmodule Helmsman.Autopilots.Autopilot do
  @moduledoc """
  An autopilot (`add-autopilots` decision 1): a target (a managed agent,
  or a squad in `create_task` mode), a mode, instructions, an optional
  cron schedule in a time zone, an overlap policy and an optional webhook
  token (only its SHA-256 is kept). `initiator_user_id` is its
  authorization source: the last person who saved it (decision 4).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @modes [:create_task, :run_only]
  @overlaps [:skip, :queue]
  @disabled_reasons [
    :manual,
    :consecutive_failures,
    :unauthorized,
    :initiator_left,
    :agent_archived,
    :project_archived
  ]

  schema "autopilots" do
    field :workspace_id, :id
    field :name, :string
    field :agent_id, :id
    field :project_id, :id
    field :mode, Ecto.Enum, values: @modes
    field :title_template, :string
    field :instructions, :string
    field :create_tasks, :boolean, default: false
    field :cron, :string
    field :timezone, :string, default: "UTC"
    field :overlap, Ecto.Enum, values: @overlaps, default: :skip
    field :enabled, :boolean, default: true
    field :next_run_at, :utc_datetime_usec
    field :webhook_token_hash, :binary, redact: true
    field :initiator_user_id, :id
    field :created_by_user_id, :id
    field :disabled_reason, Ecto.Enum, values: @disabled_reasons
    field :consecutive_failures, :integer, default: 0
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The modes."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "The overlap policies."
  @spec overlaps() :: [atom()]
  def overlaps, do: @overlaps

  @doc "Why an autopilot may be disabled."
  @spec disabled_reasons() :: [atom()]
  def disabled_reasons, do: @disabled_reasons
end

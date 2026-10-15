defmodule Helmsman.TaskSpecs.IssueNote do
  @moduledoc """
  A note in the discussion of an issue (`add-spec-workflow` decision 5):
  a `reply` (`accepted` / `disputed`), a `withdraw`, a `ruling` (`upheld` /
  `dismissed`) or a `comment` that sets no resolution. Insert only.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.Issue

  @type kind :: :reply | :withdraw | :ruling | :comment
  @type t :: %__MODULE__{}

  schema "task_spec_issue_notes" do
    field :workspace_id, :id
    belongs_to :issue, Issue
    field :number, :integer
    belongs_to :author, Actor
    belongs_to :source_run, Run
    field :kind, Ecto.Enum, values: [:reply, :withdraw, :ruling, :comment]

    field :resolution, Ecto.Enum, values: [:accepted, :disputed, :withdrawn, :upheld, :dismissed]

    field :fixed_in_version, :integer
    field :body, :string, default: ""
    field :inserted_at, :utc_datetime_usec
  end
end

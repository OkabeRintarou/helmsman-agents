defmodule Helmsman.TaskSpecs.Issue do
  @moduledoc """
  An issue of a review (`add-spec-workflow` decision 5), `R<review>.<n>`.
  `resolution` is redundant: the resolution of the last note that set one,
  `open` before that.
  """

  use Ecto.Schema

  alias Helmsman.TaskSpecs.{IssueNote, Review}

  @type resolution :: :open | :accepted | :disputed | :withdrawn | :upheld | :dismissed
  @type t :: %__MODULE__{}

  @resolutions [:open, :accepted, :disputed, :withdrawn, :upheld, :dismissed]

  schema "task_spec_issues" do
    field :workspace_id, :id
    field :spec_id, :id
    belongs_to :review, Review
    field :number, :integer
    field :severity, Ecto.Enum, values: [:P1, :P2, :P3]
    field :file, :string
    field :line, :integer
    field :anchor, :string
    field :body, :string
    field :suggestion, :string
    field :resolution, Ecto.Enum, values: @resolutions, default: :open
    field :note_seq, :integer, default: 0
    has_many :notes, IssueNote, preload_order: [asc: :number]
    field :updated_at, :utc_datetime_usec
  end

  @doc "The issue resolutions."
  @spec resolutions() :: [resolution()]
  def resolutions, do: @resolutions
end

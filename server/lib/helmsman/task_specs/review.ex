defmodule Helmsman.TaskSpecs.Review do
  @moduledoc """
  A review of a spec version (`add-spec-workflow` decision 5): verdict,
  summary and issues. Insert only; numbered `R<n>` within the spec.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.{Issue, Version}

  @type verdict :: :pass | :fail | :comment
  @type t :: %__MODULE__{}

  schema "task_spec_reviews" do
    field :workspace_id, :id
    field :spec_id, :id
    field :number, :integer
    belongs_to :version, Version
    belongs_to :reviewer, Actor
    belongs_to :source_run, Run
    field :verdict, Ecto.Enum, values: [:pass, :fail, :comment]
    field :summary, :string, default: ""
    has_many :issues, Issue, preload_order: [asc: :number]
    field :inserted_at, :utc_datetime_usec
  end
end

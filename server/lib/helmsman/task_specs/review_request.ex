defmodule Helmsman.TaskSpecs.ReviewRequest do
  @moduledoc """
  A review request on a spec version (`add-spec-workflow` decisions 2, 5,
  10): `requested`, then `submitted`, `cancelled` (with a `close_reason`)
  or `lapsed`. At most one `requested` per version and reviewer.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.{Review, Version}

  @type status :: :requested | :submitted | :cancelled | :lapsed
  @type t :: %__MODULE__{}

  schema "task_spec_review_requests" do
    field :workspace_id, :id
    field :spec_id, :id
    field :number, :integer
    belongs_to :version, Version
    belongs_to :reviewer, Actor
    belongs_to :requested_by, Actor
    belongs_to :request_run, Run
    field :note, :string, default: ""

    field :status, Ecto.Enum,
      values: [:requested, :submitted, :cancelled, :lapsed],
      default: :requested

    field :close_reason, Ecto.Enum, values: [:superseded, :withdrawn, :abandoned]
    belongs_to :review, Review
    field :closed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end

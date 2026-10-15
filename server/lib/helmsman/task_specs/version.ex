defmodule Helmsman.TaskSpecs.Version do
  @moduledoc """
  A spec version (`add-spec-workflow` decision 2): a complete set of files
  with the validation result at submission. Never updated after insert;
  whether it was ever finalized comes from the audit events (decision 6).
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.File

  @type t :: %__MODULE__{}

  schema "task_spec_versions" do
    field :workspace_id, :id
    field :spec_id, :id
    field :number, :integer
    belongs_to :author, Actor
    belongs_to :source_run, Run
    field :note, :string, default: ""
    field :validation, :map, default: %{}
    field :valid, :boolean, default: false
    has_many :files, File, preload_order: [asc: :path]
    field :inserted_at, :utc_datetime_usec
  end
end

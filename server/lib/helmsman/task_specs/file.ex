defmodule Helmsman.TaskSpecs.File do
  @moduledoc "A file of a spec version: its path and blob (`add-spec-workflow` decision 2)."

  use Ecto.Schema

  alias Helmsman.TaskSpecs.{Blob, Version}

  @type t :: %__MODULE__{}

  @primary_key false
  schema "task_spec_files" do
    field :workspace_id, :id
    belongs_to :version, Version, primary_key: true
    field :path, :string, primary_key: true
    belongs_to :blob, Blob
  end
end

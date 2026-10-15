defmodule Helmsman.TaskSpecs.Blob do
  @moduledoc """
  The content of a spec file, stored once per spec and SHA-256
  (`add-spec-workflow` decision 2).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "task_spec_blobs" do
    field :workspace_id, :id
    field :spec_id, :id
    field :sha256, :binary
    field :content, :string
    field :bytes, :integer
  end
end

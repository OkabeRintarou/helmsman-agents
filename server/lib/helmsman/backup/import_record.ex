defmodule Helmsman.Backup.ImportRecord do
  @moduledoc "A workspace backup job and its audit result."
  use Ecto.Schema
  import Ecto.Changeset

  schema "imports" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :user, Helmsman.Accounts.User
    field :mode, Ecto.Enum, values: [:merge, :replace], default: :merge
    field :dry_run, :boolean, default: false
    field :source, Ecto.Enum, values: [:helmsman, :bosun], default: :helmsman
    field :file_sha256, :string
    field :file_name, :string
    field :status, Ecto.Enum, values: [:queued, :running, :succeeded, :failed], default: :queued
    field :report, :map, default: %{}
    field :errors, {:array, :map}, default: []
    field :upload, :string
    field :options, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:workspace_id, :mode, :source, :status, :dry_run])
    |> validate_length(:file_name, max: 255)
    |> validate_length(:upload, max: 255)
    |> validate_length(:file_sha256, is: 64)
    |> validate_length(:errors, max: 100)
    |> unique_constraint(:workspace_id, name: :imports_active)
  end
end

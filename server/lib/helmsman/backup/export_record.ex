defmodule Helmsman.Backup.ExportRecord do
  @moduledoc "A workspace backup job and its audit result."
  use Ecto.Schema
  import Ecto.Changeset

  schema "exports" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :user, Helmsman.Accounts.User
    field :status, Ecto.Enum, values: [:queued, :running, :succeeded, :failed], default: :queued
    field :file, :string
    field :size, :integer
    field :sha256, :string
    field :counts, :map, default: %{}
    field :error, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:workspace_id, :user_id, :status])
    |> validate_length(:file, max: 255)
    |> validate_length(:sha256, is: 64)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> unique_constraint(:workspace_id, name: :exports_active)
  end
end

defmodule Helmsman.Daemons.Runtime do
  @moduledoc "Runtime persistence."
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "runtimes" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :daemon, Helmsman.Daemons.Daemon
    field :provider, :string
    field :cli_version, :string
    field :models, {:array, :string}, default: []
    field :efforts, {:array, :string}, default: []
    field :status, :string, default: "offline"
    field :unavailable_reason, :string
    field :vendor, :string
    field :disabled_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end

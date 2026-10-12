defmodule Helmsman.Daemons.DeviceCode do
  @moduledoc "DeviceCode persistence."
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "device_codes" do
    belongs_to :user, Helmsman.Accounts.User
    field :device_code_hash, :binary, redact: true
    field :user_code, :string
    field :machine, :map
    field :protocol_version, :integer
    field :workspace_ids, {:array, :id}, default: []
    field :status, :string, default: "pending"
    field :interval, :integer, default: 5
    field :last_polled_at, :utc_datetime
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end

defmodule Helmsman.Daemons.Daemon do
  @moduledoc "Daemon persistence."
  use Ecto.Schema
  @type t :: %__MODULE__{}
  @derive {Inspect, except: [:token_hash, :previous_token_hash]}
  schema "daemons" do
    belongs_to :user, Helmsman.Accounts.User
    field :machine_id, :string
    field :name, :string
    field :os, :string
    field :arch, :string
    field :version, :string
    field :protocol_version, :integer
    field :repo_registration, :boolean, default: false
    field :max_concurrency, :integer, default: 4
    field :token_hash, :binary, redact: true
    field :token_issued_at, :utc_datetime
    field :previous_token_hash, :binary, redact: true
    field :previous_token_expires_at, :utc_datetime
    field :auth_epoch, :integer, default: 1
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end

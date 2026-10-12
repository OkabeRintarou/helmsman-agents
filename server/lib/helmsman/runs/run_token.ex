defmodule Helmsman.Runs.RunToken do
  @moduledoc """
  The `hmr_` token of a run (designs/12 §4, 13 §2.3): only its SHA-256 is
  stored; one per run (a run is claimed once).
  """

  use Ecto.Schema

  alias Helmsman.Runs.Run

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:token_hash]}
  schema "run_tokens" do
    belongs_to :run, Run
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end

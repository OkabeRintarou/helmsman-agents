defmodule Helmsman.Avatars.Avatar do
  @moduledoc """
  An avatar (`add-actor-avatars` decision 3): a user's (`user_id`, shown on
  their human identities) or an agent's or squad's (`workspace_id` and
  `actor_id`). `key`, the first 32 hex digits of the SHA-256 of `data`, is
  the read key; `data` is only loaded when asked for.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "avatars" do
    belongs_to :user, Helmsman.Accounts.User
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :actor, Helmsman.Actors.Actor
    field :content_type, :string
    field :data, :binary, load_in_query: false, redact: true
    field :key, :string
    field :byte_size, :integer
    field :edge, :integer
    belongs_to :updated_by, Helmsman.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The read key of `data`."
  @spec key(binary()) :: String.t()
  def key(data) when is_binary(data),
    do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower) |> binary_part(0, 32)

  @doc "True when `key` has the form of a read key (32 lower-case hex digits)."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) == 32,
    do: key =~ ~r/\A[0-9a-f]{32}\z/

  def valid_key?(_key), do: false
end

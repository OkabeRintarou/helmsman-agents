defmodule Helmsman.ApiTokens.ApiToken do
  @moduledoc """
  An API token: a long-lived credential a user issues for one workspace
  (designs/03 §2). Only the SHA-256 hash of the token and the first 8
  characters after `hm_` (`prefix`) are stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.Workspace

  @type scope :: String.t()
  @type t :: %__MODULE__{}

  @scopes ~w(mcp api:read api:write)
  @scopes_message "must be one or more of: " <> Enum.join(@scopes, ", ")

  schema "api_tokens" do
    belongs_to :workspace, Workspace
    belongs_to :user, User
    field :name, :string
    field :token_hash, :binary, redact: true
    field :prefix, :string
    field :scopes, {:array, :string}
    belongs_to :default_agent, Actor
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The valid scopes."
  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @doc """
  Changeset for a new token. `workspace_id`, `user_id`, `token_hash` and
  `prefix` are set by the caller, not cast from attrs.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :scopes, :expires_at, :default_agent_id])
    |> validate_required([:workspace_id, :user_id, :token_hash, :prefix, :name])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_scopes()
    |> unique_constraint(:token_hash)
    |> check_constraint(:scopes, name: :api_tokens_scopes_check, message: @scopes_message)
    |> check_constraint(:name, name: :api_tokens_name_length, message: "must be 1-64 characters")
    |> foreign_key_constraint(:default_agent_id, name: :api_tokens_default_agent_id_fkey)
  end

  defp validate_scopes(changeset) do
    changeset
    |> update_change(:scopes, &Enum.uniq/1)
    |> validate_required(:scopes, message: @scopes_message)
    |> validate_length(:scopes, min: 1, message: @scopes_message)
    |> validate_subset(:scopes, @scopes, message: @scopes_message)
  end
end

defmodule Helmsman.Invitations.Invitation do
  @moduledoc """
  A one-time link that lets someone join a workspace with a given role.

  Only the SHA-256 hash of the token is stored. Without an `email` the
  invitation is a generic link anyone holding it may use.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Accounts.User
  alias Helmsman.Workspaces.{Membership, Workspace}

  @type t :: %__MODULE__{}

  schema "invitations" do
    belongs_to :workspace, Workspace
    field :email, :string
    field :role, Ecto.Enum, values: Membership.roles()
    field :token_hash, :binary, redact: true
    belongs_to :invited_by, User
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    belongs_to :accepted_by, User
    field :revoked_at, :utc_datetime
    belongs_to :revoked_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a new invitation. Casts `email` and `role`;
  `workspace_id`, `token_hash`, `invited_by_id` and `expires_at` are set by
  the caller.

  A blank email means a generic link; otherwise it is trimmed and
  downcased.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:workspace_id, :role, :token_hash, :invited_by_id, :expires_at])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:token_hash)
    |> check_constraint(:role, name: :invitations_role_check, message: "is invalid")
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_id)
  end

  @doc "Trims and downcases an email address."
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()
end

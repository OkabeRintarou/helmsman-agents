defmodule Helmsman.GitHub.App do
  @moduledoc """
  The instance's GitHub App created through the manifest flow (designs/15
  §1). At most one row exists. The private key, webhook secret and OAuth
  client secret are encrypted with `Helmsman.Vault` and redacted from
  `inspect`.
  """

  use Ecto.Schema

  alias Helmsman.Accounts.User
  alias Helmsman.Encrypted

  @type t :: %__MODULE__{}

  schema "github_apps" do
    field :app_id, :integer
    field :slug, :string
    field :name, :string
    field :html_url, :string
    field :owner_login, :string
    field :client_id, :string
    field :client_secret, Encrypted.Binary, redact: true
    field :private_key, Encrypted.Binary, redact: true
    field :webhook_secret, Encrypted.Binary, redact: true
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end
end

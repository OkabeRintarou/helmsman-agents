defmodule Helmsman.GitHub.Installation do
  @moduledoc """
  A GitHub App installation linked to a workspace (designs/15 §1).

  `installation_id` is GitHub's ID. `fetched_at` is when the installation
  details last applied were fetched from GitHub, `repos_fetched_at` the
  same for the repository list; results fetched earlier are never applied
  over them. `disconnected_at` is set when the workspace disconnected (or
  GitHub reported the installation gone); a disconnected installation can
  only be connected again to the same workspace.
  """

  use Ecto.Schema

  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  schema "github_installations" do
    belongs_to :workspace, Workspace
    field :installation_id, :integer
    field :account_login, :string
    field :account_type, :string
    field :suspended_at, :utc_datetime
    field :disconnected_at, :utc_datetime
    field :fetched_at, :utc_datetime_usec
    field :repos_fetched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end
end

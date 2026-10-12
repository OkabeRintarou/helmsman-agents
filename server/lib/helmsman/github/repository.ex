defmodule Helmsman.GitHub.Repository do
  @moduledoc """
  A repository an installation can access, synced from GitHub (designs/15
  §2). Rows are never deleted: a repository that left the installation's
  scope gets `removed_at`.

  A repository is available when it is not removed nor archived and its
  installation is neither disconnected nor suspended
  (`Helmsman.GitHub.Repositories.available?/2`).
  """

  use Ecto.Schema

  alias Helmsman.GitHub.Installation
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  schema "repositories" do
    belongs_to :workspace, Workspace
    belongs_to :installation, Installation
    field :github_id, :integer
    field :owner, :string
    field :name, :string
    field :default_branch, :string
    field :archived, :boolean, default: false
    field :private, :boolean, default: false
    field :removed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Returns `\"owner/name\"`."
  @spec full_name(t()) :: String.t()
  def full_name(%__MODULE__{owner: owner, name: name}), do: "#{owner}/#{name}"
end

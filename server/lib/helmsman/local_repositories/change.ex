defmodule Helmsman.LocalRepositories.Change do
  @moduledoc """
  A web request to register or remove a local repository on a daemon's
  machine (`add-local-repo-web-registration` D10): who asked, from which
  workspace, for what, and the daemon's result. `root` / `path` are set
  for registrations only; they are never logged.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @actions ~w(register remove)
  @statuses ~w(pending succeeded failed)

  schema "local_repository_changes" do
    belongs_to :daemon, Helmsman.Daemons.Daemon
    belongs_to :user, Helmsman.Accounts.User
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    field :action, :string
    field :name, :string
    field :root, :string, redact: true
    field :path, :string, redact: true
    field :workspace_ids, {:array, :integer}, default: []
    field :request_id, :string
    field :status, :string, default: "pending"
    field :error, :string
    field :message, :string
    field :inserted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
  end

  @doc "Every action."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Every status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end

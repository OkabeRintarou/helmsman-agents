defmodule Helmsman.LocalRepositories.LocalRepository do
  @moduledoc """
  A repository on a daemon's machine, registered per workspace × daemon ×
  name from the daemon's `join` / `sync` (`add-local-repositories`
  decision 4). `status`: `online`, `offline` (the daemon is) or
  `unavailable` (with `unavailable_reason`). `path` is only for display,
  to the daemon's owner and workspace owners / admins; the server never
  sends it to a daemon.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(online offline unavailable)

  schema "local_repositories" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :daemon, Helmsman.Daemons.Daemon
    field :name, :string
    field :path, :string, redact: true
    field :default_branch, :string
    field :status, :string, default: "online"
    field :unavailable_reason, :string
    field :removed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Every status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end

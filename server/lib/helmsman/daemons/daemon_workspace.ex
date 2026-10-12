defmodule Helmsman.Daemons.DaemonWorkspace do
  @moduledoc "Workspaces selected by a daemon owner."
  use Ecto.Schema
  @primary_key false
  schema "daemon_workspaces" do
    belongs_to :daemon, Helmsman.Daemons.Daemon, primary_key: true
    belongs_to :workspace, Helmsman.Workspaces.Workspace, primary_key: true
    field :inserted_at, :utc_datetime
  end
end

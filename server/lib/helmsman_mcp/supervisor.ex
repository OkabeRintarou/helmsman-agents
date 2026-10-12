defmodule HelmsmanMCP.Supervisor do
  @moduledoc """
  Starts `HelmsmanMCP.Sessions` and then the MCP server. If the session
  table goes, the server and its sessions are restarted with it.
  """

  use Supervisor

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      HelmsmanMCP.Sessions,
      {HelmsmanMCP.Server,
       transport: {:streamable_http, start: true}, session_idle_timeout: :timer.hours(24)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

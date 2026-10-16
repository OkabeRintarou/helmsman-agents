defmodule Helmsman.McpServers.Ref do
  @moduledoc false
  use Ecto.Schema

  schema "agent_mcp_server_refs" do
    field :workspace_id, :id
    field :agent_actor_id, :id
    field :server_id, :id
    field :position, :integer
  end
end

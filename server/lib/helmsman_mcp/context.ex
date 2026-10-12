defmodule HelmsmanMCP.Context do
  @moduledoc """
  What a tool call runs with: the tool name, the arguments as given (string
  keys), the caller's scope and the MCP session (`%{id, actor_id, source}`
  or nil).
  """

  alias Helmsman.Accounts.Scope

  @type session :: %{
          id: String.t(),
          actor_id: pos_integer() | nil,
          source: HelmsmanMCP.Sessions.source()
        }

  @type t :: %__MODULE__{
          tool: String.t(),
          args: %{optional(String.t()) => term()},
          scope: Scope.t(),
          session: session() | nil
        }

  @enforce_keys [:tool, :scope]
  defstruct tool: nil, args: %{}, scope: nil, session: nil
end

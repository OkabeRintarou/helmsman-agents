defmodule HelmsmanMCP.Tools.WithdrawAgent do
  @moduledoc """
  `withdraw_agent`: removes an agent from the draft
  (`add-agent-conversation` decision 7). Listed only for design runs.
  `:read` mode: it writes the conversation's draft, never as an identity
  of the session, so the pipeline resolves no writer.
  """

  use HelmsmanMCP.Tool,
    name: "withdraw_agent",
    description: "Remove an agent from the draft, by name. Only in agent design runs.",
    schema: %{name: {:required, :string, description: "The draft agent's name."}},
    mode: :read

  alias Helmsman.AgentDesigns

  @impl HelmsmanMCP.Tool
  def call(%{"name" => name}, %{scope: scope}), do: AgentDesigns.withdraw_agent(scope, name)
end

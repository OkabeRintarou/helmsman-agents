defmodule HelmsmanMCP.Tools.GetDesign do
  @moduledoc """
  `get_design`: the conversation of a design run, its draft and options
  (`add-agent-conversation` decision 7). Listed only for design runs.
  """

  use HelmsmanMCP.Tool,
    name: "get_design",
    description:
      "Read the agent design you are working on: the user, the full draft and its version, " <>
        "what the user changed in the draft before this message, and every option (runtimes, " <>
        "provider accounts, existing agents) with the field rules. Only in agent design runs.",
    schema: %{},
    mode: :read

  alias Helmsman.AgentDesigns

  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope}), do: AgentDesigns.describe(scope)
end

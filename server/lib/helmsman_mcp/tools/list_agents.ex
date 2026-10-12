defmodule HelmsmanMCP.Tools.ListAgents do
  @moduledoc "`list_agents`: the agents of the workspace and whether they are busy."

  use HelmsmanMCP.Tool,
    name: "list_agents",
    description:
      "List the agents of this workspace: managed (started by Helmsman on a runtime, see " <>
        "run_agent) or external, owner, CLI, description, whether disabled or archived, " <>
        "whether running now (busy), how many runs are queued and whether a managed " <>
        "agent is woken when a task it created makes progress (wake_on_requested).",
    schema: %{},
    mode: :read

  alias Helmsman.Agents

  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope}) do
    with {:ok, agents} <- Agents.list(scope) do
      {:ok, %{agents: Enum.map(agents, &view/1)}}
    end
  end

  defp view(agent) do
    %{
      name: agent.name,
      kind: agent.kind,
      owner: agent.owner.name,
      provider: agent.provider,
      description: agent.description,
      disabled: agent.disabled,
      archived: agent.archived,
      busy: agent.active_runs > 0,
      queued: agent.queued_runs,
      wake_on_requested: agent.wake_on_requested
    }
  end
end

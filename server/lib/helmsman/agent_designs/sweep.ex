defmodule Helmsman.AgentDesigns.Sweep do
  @moduledoc """
  Every minute (`add-agent-conversation` decision 10): cancels the design
  runs still queued 10 minutes after they were created
  (`Helmsman.AgentDesigns.sweep_queued/0`).
  """

  use Oban.Worker, queue: :runs

  alias Helmsman.AgentDesigns

  @impl true
  def perform(_job) do
    AgentDesigns.sweep_queued()
    :ok
  end
end

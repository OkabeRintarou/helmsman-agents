defmodule Helmsman.AgentDesigns.Expire do
  @moduledoc """
  Every hour (`add-agent-conversation` decision 10): expires idle
  conversations and those of users who left, and deletes the ones closed
  over 30 days ago (`Helmsman.AgentDesigns.expire/0`).
  """

  use Oban.Worker, queue: :default

  alias Helmsman.AgentDesigns

  @impl true
  def perform(_job) do
    AgentDesigns.expire()
    :ok
  end
end

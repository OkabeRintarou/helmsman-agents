defmodule Helmsman.Presence do
  @moduledoc """
  Online presence (designs/08 §6): external agents connected over MCP are
  tracked on the workspace's agents topic, keyed by session ID.
  """

  use Phoenix.Presence, otp_app: :helmsman, pubsub_server: Helmsman.PubSub

  @doc "The topic the agents online in a workspace are tracked on."
  @spec agents_topic(pos_integer()) :: String.t()
  def agents_topic(workspace_id) when is_integer(workspace_id),
    do: "workspace:#{workspace_id}:agents"
end

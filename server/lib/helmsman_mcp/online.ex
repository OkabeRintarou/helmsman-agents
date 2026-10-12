defmodule HelmsmanMCP.Online do
  @moduledoc """
  The online entries of MCP sessions on the workspace's agents topic
  (`Helmsman.Presence`), keyed by session ID and tracked for the session
  process, so they go away when it exits.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Presence
  alias HelmsmanMCP.Sessions

  @doc """
  Tracks the calling session process; an existing entry is updated
  instead (a repeated `initialize`).
  """
  @spec track(String.t(), Scope.t(), map()) :: :ok
  def track(session_id, %Scope{} = scope, client_info) do
    topic = Presence.agents_topic(scope.workspace.id)

    meta = %{
      user_id: scope.user.id,
      actor_name: nil,
      client: %{name: client_info["name"], version: client_info["version"]},
      connected_at: DateTime.utc_now()
    }

    case Presence.track(self(), topic, session_id, meta) do
      {:ok, _ref} ->
        :ok

      {:error, {:already_tracked, _pid, _topic, _key}} ->
        {:ok, _ref} =
          Presence.update(
            self(),
            topic,
            session_id,
            &Map.merge(&1, Map.delete(meta, :actor_name))
          )

        :ok
    end
  end

  @doc "Shows `actor_name` in the session's entry."
  @spec put_actor(String.t(), String.t()) :: :ok
  def put_actor(session_id, actor_name) do
    with %{pid: pid, workspace_id: workspace_id} <- Sessions.lookup(session_id) do
      Presence.update(pid, Presence.agents_topic(workspace_id), session_id, fn meta ->
        Map.put(meta, :actor_name, actor_name)
      end)
    end

    :ok
  end
end

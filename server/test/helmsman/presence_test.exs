defmodule Helmsman.PresenceTest do
  use ExUnit.Case, async: true

  alias Helmsman.Presence

  test "agents_topic/1 is per workspace" do
    assert Presence.agents_topic(42) == "workspace:42:agents"
  end

  test "an entry is listed while its process lives" do
    workspace_id = System.unique_integer([:positive])
    topic = Presence.agents_topic(workspace_id)
    Phoenix.PubSub.subscribe(Helmsman.PubSub, topic)
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _ref} = Presence.track(self(), topic, "session-1", %{actor_name: nil})
        send(parent, :tracked)
        receive do: (:stop -> :ok)
      end)

    assert_receive :tracked
    assert %{"session-1" => %{metas: [%{actor_name: nil}]}} = Presence.list(topic)
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{joins: joins}}
    assert Map.has_key?(joins, "session-1")

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
    assert Map.has_key?(leaves, "session-1")
    assert Presence.list(topic) == %{}
  end
end

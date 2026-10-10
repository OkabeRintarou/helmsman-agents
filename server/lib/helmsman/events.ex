defmodule Helmsman.Events do
  @moduledoc """
  Domain event broadcasting.

  Events describe committed changes, so they must never be broadcast from
  inside a transaction: register them with `after_commit/2` and
  `Helmsman.Tx.run/2` broadcasts them after the outermost commit.
  """

  alias Helmsman.Repo
  alias Helmsman.Tx

  @pubsub Helmsman.PubSub

  @doc "Returns the PubSub topic of a resource, e.g. `\"workspace:1\"`."
  @spec topic(:workspace | :user | :project | :task, pos_integer()) :: String.t()
  def topic(:workspace, id) when is_integer(id), do: "workspace:#{id}"
  def topic(:user, id) when is_integer(id), do: "user:#{id}"
  def topic(:project, id) when is_integer(id), do: "project:#{id}"
  def topic(:task, id) when is_integer(id), do: "task:#{id}"

  @doc "Subscribes the caller to `topic`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Broadcasts `message` on `topic` after the current transaction commits."
  @spec after_commit(String.t(), term()) :: :ok
  def after_commit(topic, message), do: Tx.after_commit(fn -> broadcast(topic, message) end)

  @doc """
  Broadcasts `message` on `topic` right away.

  Raises when called inside a transaction, in every environment.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) do
    if Repo.in_transaction?() do
      raise "Helmsman.Events.broadcast/2 called inside a transaction; " <>
              "register the event with Helmsman.Events.after_commit/2 instead"
    end

    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end
end

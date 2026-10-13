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
  @spec topic(
          :workspace
          | :user
          | :project
          | :task
          | :daemon
          | :run
          | :workspace_runs
          | :provider_accounts
          | :agent_design
          | :workspace_squads
          | :workspace_autopilots,
          pos_integer()
        ) :: String.t()
  def topic(:workspace, id) when is_integer(id), do: "workspace:#{id}"
  def topic(:user, id) when is_integer(id), do: "user:#{id}"
  def topic(:project, id) when is_integer(id), do: "project:#{id}"
  def topic(:daemon, id) when is_integer(id), do: "daemon:#{id}"
  def topic(:task, id) when is_integer(id), do: "task:#{id}"
  def topic(:run, id) when is_integer(id), do: "run:#{id}"
  def topic(:workspace_runs, id) when is_integer(id), do: "workspace:#{id}:runs"
  # The squads of a workspace (`add-squads` decision 3).
  def topic(:workspace_squads, id) when is_integer(id), do: "workspace:#{id}:squads"
  # The autopilots of a workspace (`add-autopilots` decision 12).
  def topic(:workspace_autopilots, id) when is_integer(id), do: "workspace:#{id}:autopilots"
  # A creation conversation (`add-agent-conversation` decision 4).
  def topic(:agent_design, id) when is_integer(id), do: "agent_design:#{id}"
  # A user's provider accounts (`add-provider-accounts` decision 3).
  def topic(:provider_accounts, user_id) when is_integer(user_id),
    do: "user:#{user_id}:provider_accounts"

  @doc """
  Like `after_commit/2`, but `message` is broadcast on `topic` once per
  transaction for `key`: a later registration replaces the message.
  """
  @spec after_commit_once(term(), String.t(), term()) :: :ok
  def after_commit_once(key, topic, message),
    do: Tx.after_commit_once({topic, key}, fn -> broadcast(topic, message) end)

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

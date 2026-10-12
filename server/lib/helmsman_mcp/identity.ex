defmodule HelmsmanMCP.Identity do
  @moduledoc """
  The identity of an MCP session (designs/03 §4): the session identity set
  by `identify` or created on the first write, else the token's default
  agent.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias HelmsmanMCP.{Context, Online, Sessions}

  @type source :: String.t()

  @doc """
  Returns where the current identity comes from: `"identify"`, `"auto"`,
  `"default"`, `"run"` (a run token: always its agent) or `"none"`.
  """
  @spec source(Scope.t(), Context.session() | nil) :: source()
  def source(%Scope{via: :run}, _session), do: "run"

  def source(_scope, %{actor_id: id, source: source}) when is_integer(id),
    do: Atom.to_string(source)

  def source(%Scope{token: %ApiToken{default_agent_id: id}}, _session) when is_integer(id),
    do: "default"

  def source(_scope, _session), do: "none"

  @doc """
  Returns the current identity, read without a lock; it may be disabled.
  """
  @spec current(Scope.t(), Context.session() | nil) :: Actor.t() | nil
  def current(%Scope{via: :run, actor: actor}, _session), do: actor

  def current(%Scope{workspace: workspace}, %{actor_id: id}) when is_integer(id),
    do: Actors.get(workspace.id, id)

  def current(%Scope{workspace: workspace, token: %ApiToken{default_agent_id: id}}, _session)
      when is_integer(id),
      do: Actors.get(workspace.id, id)

  def current(_scope, _session), do: nil

  @doc """
  Makes `actor` the session identity and shows it in the session's online
  entry. Does nothing without a session.
  """
  @spec put(Context.session() | nil, Actor.t(), :identify | :auto) :: :ok
  def put(nil, _actor, _source), do: :ok

  def put(%{id: session_id}, %Actor{} = actor, source) do
    with :ok <- Sessions.put_identity(session_id, actor.id, source) do
      Online.put_actor(session_id, actor.name)
    end

    :ok
  end
end

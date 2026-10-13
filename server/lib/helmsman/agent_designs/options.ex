defmodule Helmsman.AgentDesigns.Options do
  @moduledoc """
  What a draft agent of a conversation may be bound to
  (`add-agent-conversation` decisions 7, 8): the runtimes the
  conversation's user may bind in the workspace (not disabled, on their
  own daemons) and their own provider accounts (ID, name and CLI only),
  with the workspace's existing agents and the rules of each field.
  Never a key, an address or an environment value.
  """

  import Ecto.Query

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.Draft
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.ProviderAccounts.ProviderAccount
  alias Helmsman.Repo

  @max_accounts 32

  @rules [
    "name: 1-64 characters of a-z, 0-9, '.', '_', '/' and '-', starting with a letter or digit; " <>
      "unique in the workspace and in the draft",
    "provider: the CLI (#{Enum.map_join(HelmsmanProtocol.providers(), ", ", &to_string/1)}); " <>
      "it must match the runtime and the provider account",
    "runtime_id: one of the runtimes above (optional; without one the agent cannot run)",
    "provider_account_id: one of the provider accounts above, for the same CLI (optional)",
    "model, effort: one of the runtime's values when it reports any; with a provider account " <>
      "the model is free text",
    "instructions: who the agent is, how it works and what it delivers (at most 64 KB)",
    "description: one line for people (at most 1000 characters)",
    "capabilities: [] or [\"create_tasks\"] (the agent may create tasks)",
    "access: owner_only (default; only the user may trigger it) or workspace (every member)",
    "max_concurrency: 1-16 (default 2); timeout_minutes: 1-1200 (default 120); " <>
      "idle_timeout_minutes: 1-240 (default 20), at most timeout_minutes",
    "at most #{Draft.max_agents()} agents; environment variables, extra MCP servers, " <>
      "CLI arguments and member lists cannot be proposed"
  ]

  @doc "The rules of the draft fields, one line each."
  @spec rules() :: [String.t()]
  def rules, do: @rules

  @doc """
  The runtimes `user_id` may bind in the workspace, online first, then by
  ID: `%{id, daemon_name, provider, status, models, efforts}`.
  """
  @spec runtimes(pos_integer(), pos_integer()) :: [map()]
  def runtimes(workspace_id, user_id) do
    Repo.all(
      from(r in Runtime,
        join: d in Daemon,
        on: d.id == r.daemon_id,
        where:
          r.workspace_id == ^workspace_id and d.user_id == ^user_id and is_nil(r.disabled_at),
        order_by: [desc: r.status == "online", asc: r.id],
        select: %{
          id: r.id,
          daemon_name: d.name,
          provider: r.provider,
          status: r.status,
          models: r.models,
          efforts: r.efforts
        }
      )
    )
  end

  @doc "At most #{@max_accounts} provider accounts of `user_id`: `%{id, name, cli}`."
  @spec accounts(pos_integer()) :: [map()]
  def accounts(user_id) do
    Repo.all(
      from(a in ProviderAccount,
        where: a.user_id == ^user_id,
        order_by: [asc: a.name, asc: a.id],
        limit: @max_accounts,
        select: %{id: a.id, name: a.name, cli: a.cli}
      )
    )
  end

  @doc """
  The workspace's agents, archived ones left out: `%{name, kind: "managed"
  | "external", provider, description}`.
  """
  @spec agents(pos_integer()) :: [map()]
  def agents(workspace_id) do
    Repo.all(
      from(a in Actor,
        left_join: p in AgentProfile,
        on: p.actor_id == a.id,
        where: a.workspace_id == ^workspace_id and a.kind == :agent and is_nil(p.archived_at),
        order_by: a.name,
        select: %{
          name: a.name,
          kind: fragment("CASE WHEN ? IS NULL THEN 'external' ELSE 'managed' END", p.id),
          provider: p.provider,
          description: p.description
        }
      )
    )
  end

  @doc "One line describing `runtime` (a `runtimes/2` element)."
  @spec runtime_line(map()) :: String.t()
  def runtime_line(runtime) do
    "#{runtime.id}: #{runtime.provider} on #{runtime.daemon_name}, #{runtime.status}" <>
      list("models", runtime.models) <> list("efforts", runtime.efforts)
  end

  defp list(_label, []), do: ""
  defp list(_label, nil), do: ""
  defp list(label, values), do: "; #{label} #{Enum.join(values, ", ")}"
end

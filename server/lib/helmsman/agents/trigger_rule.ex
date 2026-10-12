defmodule Helmsman.Agents.TriggerRule do
  @moduledoc """
  Who may trigger a managed agent (designs/13 §2.2), on rows the caller
  has read: the single rule behind `Helmsman.Agents.trigger_check/3`,
  `Helmsman.Agents.may_trigger?/4` and `Helmsman.Dispatch.availability/1`.
  Pure: it never reads the database.
  """

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile

  @trigger_roles [:owner, :admin, :member]

  @type error :: :not_managed | :agent_archived | :agent_disabled | :unauthorized

  @doc """
  Whether the user `user_id`, whose role in the agent's workspace is
  `role` (nil: not a member), may trigger `actor` with `profile` (nil: an
  external agent). In order: `:not_managed`, `:agent_archived`,
  `:agent_disabled`, then `:unauthorized` unless the user is a member or
  above and the agent's access includes them.
  """
  @spec check(AgentProfile.t() | nil, Actor.t(), {pos_integer() | nil, atom() | nil}) ::
          :ok | {:error, error()}
  def check(nil, _actor, _user), do: {:error, :not_managed}

  def check(%{archived_at: archived}, _actor, _user) when not is_nil(archived),
    do: {:error, :agent_archived}

  def check(_profile, %{disabled_at: disabled}, _user) when not is_nil(disabled),
    do: {:error, :agent_disabled}

  def check(profile, actor, {user_id, role}) do
    if may_trigger?(profile, actor, user_id, role), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  The access part of `check/3`, ignoring whether the agent is disabled or
  archived.
  """
  @spec may_trigger?(AgentProfile.t() | nil, Actor.t(), pos_integer() | nil, atom() | nil) ::
          boolean()
  def may_trigger?(nil, _actor, _user_id, _role), do: false

  def may_trigger?(profile, actor, user_id, role),
    do: role in @trigger_roles and not is_nil(user_id) and access?(profile, actor, user_id)

  defp access?(profile, actor, user_id) do
    user_id == actor.owner_id or profile.access == "workspace" or
      (profile.access == "members" and user_id in (profile.access_member_ids || []))
  end
end

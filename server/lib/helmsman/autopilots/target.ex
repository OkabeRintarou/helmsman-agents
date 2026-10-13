defmodule Helmsman.Autopilots.Target do
  @moduledoc """
  The target of an autopilot (`add-autopilots` decision 3): a managed
  agent, or (only in `create_task` mode) a squad identity whose leader
  runs. Loads the rows and applies the trigger rules on them; never locks
  (callers that need locks take them in the global order).
  """

  import Ecto.Query

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Repo
  alias Helmsman.Squads
  alias Helmsman.Workspaces.Membership

  @type t :: %{
          actor: Actor.t(),
          profile: AgentProfile.t() | nil,
          squad: Squads.loaded() | nil
        }

  @type refusal ::
          :unauthorized
          | :agent_archived
          | :agent_disabled
          | :squad_disabled
          | :no_runtime
          | :runtime_disabled

  @doc "The target with identity `actor_id` (unlocked), or nil."
  @spec load(pos_integer() | nil) :: t() | nil
  def load(nil), do: nil

  def load(actor_id) do
    case Repo.get(Actor, actor_id) do
      nil -> nil
      actor -> of_actor(actor)
    end
  end

  @doc "The target for the identity row `actor` (its other rows read unlocked)."
  @spec of_actor(Actor.t()) :: t()
  def of_actor(%Actor{kind: :squad} = actor) do
    squad = with %{} = s <- Squads.by_actor_id(actor.id), do: Squads.load(s)
    %{actor: actor, profile: nil, squad: squad}
  end

  def of_actor(%Actor{} = actor),
    do: %{actor: actor, profile: Repo.get_by(AgentProfile, actor_id: actor.id), squad: nil}

  @doc "The role of `user_id` in the workspace, or nil."
  @spec role_of(pos_integer(), pos_integer() | nil) :: atom() | nil
  def role_of(_ws, nil), do: nil

  def role_of(ws, user_id),
    do:
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^ws and m.user_id == ^user_id,
          select: m.role
        )
      )

  @doc """
  Why `target` may not be the target of an autopilot in `mode`, as a
  message for the `agent` field, or nil. An archived agent or a disabled
  squad may not be chosen; a squad only in `create_task` mode.
  """
  @spec field_error(t() | nil, atom()) :: String.t() | nil
  def field_error(nil, _mode), do: "does not exist"

  def field_error(%{actor: %Actor{kind: :squad}, squad: squad}, mode) do
    cond do
      mode == :run_only or is_nil(squad) -> "must be a managed agent"
      not is_nil(squad.actor.disabled_at) -> "is a disabled squad"
      true -> nil
    end
  end

  def field_error(
        %{actor: %Actor{kind: :agent}, profile: %AgentProfile{archived_at: nil}},
        _mode
      ),
      do: nil

  def field_error(%{actor: %Actor{kind: :agent}, profile: %AgentProfile{}}, _mode),
    do: "is archived"

  def field_error(_target, _mode), do: "must be a managed agent"

  @doc """
  Whether the user `user_id` with `role` may trigger the target by its
  access rules alone (who may manage the autopilot, decision 4): the
  agent's `access`, or for a squad its leader's and active managed
  members'. Whether it is disabled or archived does not matter.
  """
  @spec may_trigger?(t(), pos_integer() | nil, atom() | nil) :: boolean()
  def may_trigger?(%{squad: %{} = squad}, user_id, role) do
    TriggerRule.may_trigger?(squad.leader_profile, squad.leader, user_id, role) and
      Enum.all?(active_agent_members(squad), fn %{actor: actor, profile: profile} ->
        TriggerRule.may_trigger?(profile, actor, user_id, role)
      end)
  end

  # A squad with no squad row behind its identity: nobody.
  def may_trigger?(%{actor: %Actor{kind: :squad}, squad: nil}, _user_id, _role), do: false

  def may_trigger?(%{actor: actor, profile: profile}, user_id, role),
    do: TriggerRule.may_trigger?(profile, actor, user_id, role)

  @doc """
  The trigger check of an execution (decision 6, step 5): the user may
  trigger the target, which is neither archived nor disabled and has a
  runtime that is not disabled (a squad: its leader's). Reads the runtime
  unlocked.
  """
  @spec check(t() | nil, pos_integer() | nil, atom() | nil) :: :ok | {:error, refusal()}
  def check(nil, _user_id, _role), do: {:error, :agent_archived}

  def check(%{squad: %{} = squad}, user_id, role) do
    case Squads.check_loaded(squad, {user_id, role}) do
      :ok -> runtime(squad.leader_profile)
      {:error, :unauthorized, _refused} -> {:error, :unauthorized}
      {:error, :not_managed} -> {:error, :agent_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  def check(%{squad: nil, actor: %Actor{kind: :squad}}, _user_id, _role),
    do: {:error, :agent_archived}

  def check(%{actor: actor, profile: profile}, user_id, role) do
    case TriggerRule.check(profile, actor, {user_id, role}) do
      :ok -> runtime(profile)
      {:error, :not_managed} -> {:error, :agent_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime(%AgentProfile{runtime_id: nil}), do: {:error, :no_runtime}

  defp runtime(%AgentProfile{runtime_id: id}) do
    case Repo.get(Runtime, id) do
      %Runtime{disabled_at: nil} -> :ok
      _ -> {:error, :runtime_disabled}
    end
  end

  defp runtime(nil), do: {:error, :agent_archived}

  # The managed members `Helmsman.Squads.check_loaded/2` checks: neither
  # disabled nor archived.
  defp active_agent_members(squad) do
    Enum.filter(squad.members, fn %{actor: actor, profile: profile} ->
      actor.kind == :agent and not is_nil(profile) and is_nil(profile.archived_at) and
        is_nil(actor.disabled_at)
    end)
  end

  @doc "The managed agent that runs for the target (a squad's leader)."
  @spec runner(t()) :: {Actor.t(), AgentProfile.t() | nil}
  def runner(%{squad: %{} = squad}), do: {squad.leader, squad.leader_profile}
  def runner(%{actor: actor, profile: profile}), do: {actor, profile}
end

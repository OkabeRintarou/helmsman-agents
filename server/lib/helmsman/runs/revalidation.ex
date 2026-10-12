defmodule Helmsman.Runs.Revalidation do
  @moduledoc """
  Whether a claimed or claimable run is still valid (designs/13 §4.1–4.2,
  `add-run-lifecycle` decision 4). A pure function of the run and of the
  rows the caller locked (decision 24); it never reads the database.

  A run is obsolete when its agent is disabled or archived, its runtime is
  disabled or no longer the agent's, a `work` run's task is `cancelled` or
  `verified`, or it runs only because of its task's assignee
  (`Helmsman.Runs.Triggers.assignee_bound?/1`) and the assignee is no
  longer the agent.

  Each trigger with an authorization source (`initiator_user_id`) is
  checked again like `Helmsman.Agents.trigger_check/3`, on the locked
  membership rows. Invalid triggers are dropped; none left is
  `:unauthorized`. A run without any such trigger is checked with its
  `root_initiator_user_id`.
  """

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Run, Triggers}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  @type locked :: %{
          required(:members) => %{pos_integer() => Membership.role()},
          required(:agent) => Actor.t(),
          required(:profile) => AgentProfile.t() | nil,
          required(:task) => Task.t() | nil,
          required(:runtime) => Runtime.t() | nil
        }
  @type obsolete_why ::
          :agent_disabled
          | :agent_archived
          | :runtime_disabled
          | :runtime_changed
          | :task_closed
          | :reassigned
  @type result ::
          :ok
          | {:obsolete, obsolete_why()}
          | :unauthorized
          | {:pruned,
             %{
               triggers: [map()],
               root_initiator_user_id: pos_integer(),
               causal_agent_ids: [pos_integer()]
             }}

  @doc "Checks `run` against the `locked` rows; see the module documentation."
  @spec check(Run.t(), locked()) :: result()
  def check(%Run{} = run, locked) do
    case obsolete(run, locked) do
      nil -> authorization(run, locked)
      why -> {:obsolete, why}
    end
  end

  defp obsolete(run, %{agent: agent, profile: profile, runtime: runtime, task: task}) do
    agent_obsolete(agent, profile) || runtime_obsolete(run, profile, runtime) ||
      task_obsolete(run, task, agent)
  end

  defp agent_obsolete(agent, profile) do
    cond do
      not is_nil(agent.disabled_at) -> :agent_disabled
      is_nil(profile) or not is_nil(profile.archived_at) -> :agent_archived
      true -> nil
    end
  end

  defp runtime_obsolete(run, profile, runtime) do
    cond do
      is_nil(runtime) or not is_nil(runtime.disabled_at) -> :runtime_disabled
      run.runtime_id != profile.runtime_id -> :runtime_changed
      true -> nil
    end
  end

  defp task_obsolete(run, task, agent) do
    cond do
      closed_work?(run, task) -> :task_closed
      reassigned?(run, task, agent) -> :reassigned
      true -> nil
    end
  end

  defp closed_work?(%Run{lane: :work}, %Task{status: status}),
    do: status in [:cancelled, :verified]

  defp closed_work?(_run, _task), do: false

  defp reassigned?(_run, nil, _agent), do: false

  defp reassigned?(run, %Task{assignee_id: assignee_id}, %Actor{id: agent_id}),
    do: assignee_id != agent_id and Triggers.assignee_bound?(run.triggers)

  defp authorization(run, locked) do
    sources = Enum.filter(run.triggers, &source?/1)

    if sources == [] do
      if allowed?(run.root_initiator_user_id, locked), do: :ok, else: :unauthorized
    else
      prune(run, locked)
    end
  end

  defp prune(run, locked) do
    kept =
      Enum.filter(run.triggers, &(not source?(&1) or allowed?(&1["initiator_user_id"], locked)))

    case Enum.filter(kept, &source?/1) do
      [] ->
        :unauthorized

      _sources when length(kept) == length(run.triggers) ->
        :ok

      [first | _] = sources ->
        causal =
          sources
          |> Enum.flat_map(&(&1["causal_agent_ids"] || []))
          |> Enum.concat([run.agent_id])
          |> Enum.uniq()
          |> Enum.sort()

        {:pruned,
         %{
           triggers: kept,
           root_initiator_user_id: first["initiator_user_id"],
           causal_agent_ids: causal
         }}
    end
  end

  defp source?(%{"initiator_user_id" => id}) when is_integer(id), do: true
  defp source?(_trigger), do: false

  defp allowed?(user_id, %{members: members, agent: agent, profile: profile}),
    do: Agents.may_trigger?(profile, agent, user_id, Map.get(members, user_id))
end

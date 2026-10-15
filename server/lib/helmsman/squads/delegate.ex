defmodule Helmsman.Squads.Delegate do
  @moduledoc """
  `delegate(task_id, to, instructions)` (`add-squads` decision 8): a run
  as a squad leader hands its task to a managed member, which works on
  the same task, branch and pull request after the leader's run ends.

  In one write transaction, after the squad's rows (`Helmsman.Squads.Dispatch.lock_rows/1`)
  and the task row are locked, the first failing check is the error and
  nothing is written: the task is `new` or `in_progress` (`task_closed`),
  its assignee is the run's squad (`not_squad_task`), the squad is not
  disabled (`squad_disabled`), the run's agent still leads it
  (`not_leader`), `to` is a member (`not_member`) and not a person
  (`person_member`). Then the member gets a `delegated` trigger through
  `Helmsman.Runs.enqueue/3`, with the authorization source and causal chain
  of the leader's run; the trigger records the instructions, the squad
  and the leader's run. Not dispatched (`unauthorized`, a refused chain,
  ...) is a result: the transaction commits.

  `spec` (`add-spec-workflow` decision 9): `nil`, `"draft"`, `"review"` or
  `"revise"` (anything else → `{:spec, :invalid_params, _}`). With a role,
  the spec row is locked after the task row and checked before the squad
  checks (`Helmsman.TaskSpecs.Delegation.check/3`); the trigger records
  `"spec_role"`. `review` makes a review request of the latest version
  for the member, recorded on the trigger (`"spec_request"`,
  `"spec_version"`), inserted only when the run is queued or merged; a
  person member gets only the request (`%{result: :requested, reviewer,
  request}`), no run.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Policy, Repo, Runs, Tasks, Workspaces}
  alias Helmsman.Runs.{Origin, Run}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.TaskSpecs.Delegation

  @max_instructions_bytes 8192
  @open [:new, :in_progress]

  @type error ::
          :forbidden
          | :not_found
          | :busy
          | :instructions_required
          | {:invalid_instructions, :too_long | :not_a_string}
          | {:delegate, :task_closed | :squad_disabled | :not_leader, String.t()}
          | {:delegate, :not_squad_task, String.t()}
          | {:delegate, :not_member, {String.t(), [String.t()]}}
          | {:delegate, :person_member, String.t()}
          | {:spec, atom(), term()}

  @type result ::
          %{
            required(:result) => :queued | :merged,
            required(:run) => Runs.summary(),
            optional(:request) => pos_integer()
          }
          | %{result: :requested, reviewer: String.t(), request: pos_integer()}
          | %{
              result: :skipped,
              reason: atom(),
              member: String.t(),
              initiator: String.t() | nil
            }

  @doc "See the module documentation."
  @spec delegate(Scope.t(), String.t(), String.t(), term(), term()) ::
          {:ok, result()} | {:error, error()}
  def delegate(%Scope{} = scope, task_ident, to, instructions, spec \\ nil)
      when is_binary(task_ident) and is_binary(to) do
    with :ok <- Policy.authorize(scope, :delegate),
         {:ok, instructions} <- normalize(instructions),
         {:ok, role} <- Delegation.role(spec),
         {:ok, ident, _key, _seq} <- Ident.parse(task_ident) do
      Workspaces.write_transaction(
        scope,
        :delegate,
        nil,
        &locked(&1, ident, to, instructions, role)
      )
    end
  end

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:error, :instructions_required}

      text when byte_size(text) > @max_instructions_bytes ->
        {:error, {:invalid_instructions, :too_long}}

      text ->
        {:ok, text}
    end
  end

  defp normalize(nil), do: {:error, :instructions_required}
  defp normalize(_other), do: {:error, {:invalid_instructions, :not_a_string}}

  # Lock order: the squad's identity rows, its `squads` row and profiles,
  # then the task row (designs/01 §4).
  # Lock order: the squad's rows, the task row, then (with a spec role)
  # the spec row (`add-spec-workflow` decision 13).
  defp locked(%Scope{run: %Run{squad_id: squad_id} = run} = scope, ident, to, instructions, role)
       when is_integer(squad_id) do
    squad = Repo.get!(Squad, squad_id)

    with {:ok, loaded} <- SquadDispatch.lock_rows(squad.actor_id),
         {:ok, task} <- Tasks.lock(scope, ident),
         :ok <- Policy.authorize(scope, :write_task, task),
         {:ok, spec} <- Delegation.check(role, task, to),
         :ok <- check(task, loaded, run),
         {:ok, member} <- member(loaded, to, role) do
      case member do
        {:person, actor} -> {:ok, Delegation.request_person(scope, task, spec, actor)}
        member -> enqueue(scope, task, loaded, member, instructions, {role, spec})
      end
    end
  end

  defp locked(_scope, _ident, _to, _instructions, _role), do: {:error, :forbidden}

  defp check(%Task{status: status, ident: ident}, _loaded, _run) when status not in @open,
    do: {:error, {:delegate, :task_closed, ident}}

  defp check(task, loaded, run) do
    name = loaded.actor.name

    cond do
      task.assignee_id != loaded.actor.id -> {:error, {:delegate, :not_squad_task, name}}
      loaded.actor.disabled_at -> {:error, {:delegate, :squad_disabled, name}}
      loaded.squad.leader_agent_id != run.agent_id -> {:error, {:delegate, :not_leader, name}}
      true -> :ok
    end
  end

  defp member(loaded, to, role) do
    name = to |> String.trim() |> String.downcase()

    case Enum.find(loaded.members, &(&1.actor.name == name)) do
      nil ->
        {:error, {:delegate, :not_member, {loaded.actor.name, delegable(loaded)}}}

      # A person member reviews without a run (`add-spec-workflow` decision 9).
      %{actor: %Actor{kind: :human} = actor} when role == "review" ->
        {:ok, {:person, actor}}

      %{actor: %Actor{kind: :human, name: person}} ->
        {:error, {:delegate, :person_member, person}}

      member ->
        {:ok, member}
    end
  end

  # The managed members that may be delegated now.
  defp delegable(loaded) do
    for %{actor: %Actor{kind: :agent} = actor, profile: profile} <- loaded.members,
        not is_nil(profile) and is_nil(actor.disabled_at),
        do: actor.name
  end

  defp enqueue(scope, task, loaded, member, instructions, {role, spec}) do
    trigger = %{
      kind: :delegated,
      instructions: instructions,
      extra:
        Map.merge(
          %{"squad_id" => loaded.squad.id, "leader_run_id" => scope.run.id},
          Delegation.trigger_extra(role, spec)
        )
    }

    target = %{agent: member.actor, profile: member.profile, task: task, lane: :work}
    {:ok, outcome} = Runs.enqueue(Origin.from_scope(scope), target, trigger)

    case outcome do
      %{result: result, run_id: id} when result in [:queued, :merged] ->
        request = Delegation.request_member(scope, task, spec, role, member.actor)
        result = %{result: result, run: Runs.summary(Repo.get!(Run, id))}
        {:ok, if(request, do: Map.put(result, :request, request), else: result)}

      %{result: :skipped, reason: reason} ->
        {:ok,
         %{
           result: :skipped,
           reason: reason,
           member: member.actor.name,
           initiator: initiator_name(task.workspace_id, scope.run.root_initiator_user_id)
         }}
    end
  end

  defp initiator_name(workspace_id, user_id) do
    Repo.one(
      from(a in Actor,
        where: a.workspace_id == ^workspace_id and a.user_id == ^user_id and a.kind == :human,
        select: a.name
      )
    )
  end
end

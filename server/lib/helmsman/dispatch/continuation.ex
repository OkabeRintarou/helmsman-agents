defmodule Helmsman.Dispatch.Continuation do
  @moduledoc """
  Continuation triggers (`add-continuation-triggers` decisions 3–4, 7):
  `reopen`, `resubmit`, `requested` and `answer`, plus the mentions of
  `Helmsman.Dispatch.Mentions`, decided and enqueued in the write that
  causes them.

  A write plans its triggers under the task row lock, before writing
  anything (`plan_transition/5`, `plan_feedback/4`, the `targets_fun` of
  `Helmsman.Dispatch.Targets.with_locked/4`), and runs the plan after its
  writes (`run_transition/4`, `run_feedback/4`). Only managed agents are
  triggered, never the identity that caused the write; people, external
  agents and the system identity get no result.

  A continuation inherits its authorization source and causal chain
  (decision 3): `reopen` and `resubmit` from the task's `assign` grant of
  the agent, `requested` from its `requested` grant, `answer` from the run
  the question was written in; none → `skipped / no_grant`. The chain
  leaves out the target itself. Everything else is `Helmsman.Runs.enqueue/3`.

  Squads (`add-squads` decision 6): a squad target (the assignee of a
  reopened or resubmitted task, a mentioned squad) is a run of its current
  leader as the squad (`Helmsman.Squads.Dispatch`), never when the leader
  caused the write; `reopen` and `resubmit` inherit the task's `assign`
  grant of the squad identity. An answer to a question written in a run
  as a squad, and the callback of a task created in one, run as that squad
  again. Anyone on the assignee side of a squad's task (the leader, a
  member) who writes a question calls back its requester.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Dispatch.Mentions
  alias Helmsman.Feedback.{Entry, Replies}
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome, Run, TaskGrant, Triggers}
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks.Task

  @closed [:verified, :cancelled]

  @type item :: %{
          required(:kind) => :reopen | :resubmit | :requested | :answer | :mention,
          required(:agent_id) => pos_integer(),
          optional(:extra) => map(),
          optional(:question) => Entry.t(),
          optional(:steer_run_id) => pos_integer()
        }
  @type feedback_plan :: %{mentions: [pos_integer()], items: [item()]}
  @type plan :: %{transition: [item()], feedback: feedback_plan() | nil}

  ## Planning

  @doc """
  The candidate targets of a write to the task `ident` with feedback
  `content` (nil: none), read without locks: the task's assignee and
  creator, the author of its last open question and the mentioned
  identities.
  """
  @spec guess(pos_integer(), String.t(), String.t() | nil) :: [pos_integer()]
  def guess(workspace_id, ident, content) do
    task =
      Repo.one(
        from(t in Task,
          where: t.workspace_id == ^workspace_id and t.ident == ^ident,
          select: %{id: t.id, assignee_id: t.assignee_id, created_by_id: t.created_by_id}
        )
      )

    from_task =
      case task do
        nil -> []
        task -> [task.assignee_id, task.created_by_id, last_question_author(task.id)]
      end

    (from_task ++ Mentions.resolve(workspace_id, content))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp last_question_author(task_id) do
    case last_question(task_id) do
      %Entry{author_id: id} -> id
      nil -> nil
    end
  end

  # The active question the task waits on: the last of its active
  # questions and answers, when it is a question.
  defp last_question(task_id) do
    Repo.one(
      from(f in Entry,
        where: f.task_id == ^task_id and f.status == :active and f.kind in [:question, :answer],
        order_by: [desc: f.thread_seq],
        limit: 1
      )
    )
    |> case do
      %Entry{kind: :question} = entry -> entry
      _none -> nil
    end
  end

  @doc """
  Plans the triggers of moving the locked `task` to `to` with the reason
  `reason` (a `Helmsman.Feedback.normalize/1` input or nil). Options:
  `auto_reason` (`Helmsman.Tasks.auto_reopen/2`). Returns the agent
  actor IDs it may trigger and the plan.
  """
  @spec plan_transition(Scope.t(), Task.t(), Task.status(), map() | nil, keyword()) ::
          {[pos_integer()], plan()}
  def plan_transition(%Scope{} = scope, %Task{} = task, to, reason, opts \\ []) do
    by = scope.actor.id
    assignee = assignee_after(task, to, by)
    question = reason && reason_question(task, reason)
    mentions = if reason, do: Mentions.resolve(task.workspace_id, reason.content), else: []

    agents =
      agent_ids([task.assignee_id, task.created_by_id, question_author(question)] ++ mentions)

    transition =
      (continuation_items(task, to, opts) ++ requested_items(task, to))
      |> keep(agents, by)

    feedback =
      if reason, do: feedback_plan(scope, task, assignee, reason, nil, mentions, question, agents)

    {targets(transition, feedback), %{transition: transition, feedback: feedback}}
  end

  @doc """
  Plans the triggers of writing feedback `input` to the locked `task`, as
  a revision of `old` (nil: a new record).
  """
  @spec plan_feedback(Scope.t(), Task.t(), map(), Entry.t() | nil) :: {[pos_integer()], plan()}
  def plan_feedback(%Scope{} = scope, %Task{} = task, input, old) do
    reason = Map.put(input, :kind, input[:kind] || (old && old.kind))
    reason = if old, do: Map.put(reason, :reply_to_seq, old.reply_to_seq), else: reason
    question = reason_question(task, reason)
    mentions = Mentions.resolve(task.workspace_id, input.content)
    agents = agent_ids([task.created_by_id, question_author(question)] ++ mentions)

    feedback =
      feedback_plan(scope, task, task.assignee_id, input, old, mentions, question, agents)

    {targets([], feedback), %{transition: [], feedback: feedback}}
  end

  # Claiming makes the acting identity the assignee.
  defp assignee_after(%Task{status: :new, assignee_id: nil}, :in_progress, by), do: by
  defp assignee_after(%Task{assignee_id: id}, _to, _by), do: id

  defp continuation_items(%Task{status: from, assignee_id: id}, :in_progress, opts)
       when from in [:done, :verified] and not is_nil(id) do
    extra = %{"from" => Atom.to_string(from)}

    extra =
      case opts[:auto_reason] do
        nil -> extra
        reason -> Map.put(extra, "reason", Atom.to_string(reason))
      end

    [%{kind: :reopen, agent_id: id, extra: extra}]
  end

  defp continuation_items(%Task{status: :rejected, assignee_id: id}, :new, _opts)
       when not is_nil(id),
       do: [%{kind: :resubmit, agent_id: id, extra: %{}}]

  defp continuation_items(_task, _to, _opts), do: []

  defp requested_items(%Task{created_by_id: id}, to) when to in [:done, :rejected],
    do: [%{kind: :requested, agent_id: id, extra: %{"event" => Atom.to_string(to)}}]

  defp requested_items(_task, _to), do: []

  # Explicit replies select their question; both paths require an open
  # question so revising an already answered record does not trigger again.
  defp reason_question(%Task{open_question: true, id: id}, %{kind: :answer, reply_to_seq: seq})
       when is_integer(seq) do
    case Replies.current(id, seq) do
      %Entry{kind: :question} = question -> question
      _ -> nil
    end
  end

  defp reason_question(%Task{open_question: true, id: id}, %{kind: :answer}),
    do: last_question(id)

  defp reason_question(_task, _input), do: nil

  defp question_author(nil), do: nil
  defp question_author(%Entry{author_id: id}), do: id

  # A system-written record triggers nothing (designs/06 §3b).
  defp feedback_plan(
         %Scope{actor: %Actor{kind: :system}},
         _task,
         _assignee,
         _input,
         _old,
         m,
         _q,
         _a
       ),
       do: %{mentions: m, items: []}

  defp feedback_plan(scope, task, assignee, input, old, mentions, question, agents) do
    by = scope.actor.id
    kind = input[:kind] || (old && old.kind) || :comment
    requested = question_items(task, kind, old, assignee_side?(assignee, by))
    answer = answer_items(kind, question)

    mention =
      mentions
      |> Mentions.targets(old, by, MapSet.new(Map.keys(agents)))
      |> Enum.reject(&(agents[&1] == by))
      |> Enum.map(&%{kind: :mention, agent_id: &1, extra: %{}})

    %{mentions: mentions, items: keep(requested ++ answer, agents, by) ++ mention}
  end

  # The assignee writes a question (new, or a revision into one).
  defp question_items(task, :question, old, true) when is_nil(old) or old.kind != :question,
    do: [%{kind: :requested, agent_id: task.created_by_id, extra: %{"event" => "question"}}]

  defp question_items(_task, _kind, _old, _assignee?), do: []

  defp answer_items(:answer, %Entry{author_id: id} = question),
    do: [%{kind: :answer, agent_id: id, question: question, extra: %{}}]

  defp answer_items(_kind, _question), do: []

  # `agents`: target ID => the leader for a squad, nil for an agent. A
  # squad is never triggered by its own leader.
  defp keep(items, agents, by),
    do:
      Enum.filter(
        items,
        &(Map.has_key?(agents, &1.agent_id) and &1.agent_id != by and agents[&1.agent_id] != by)
      )

  # `by` is the assignee, or on its side when the assignee is a squad
  # (`add-squads` decision 11).
  defp assignee_side?(nil, _by), do: false
  defp assignee_side?(by, by), do: true

  defp assignee_side?(assignee, by),
    do: by in Squads.assignee_side(%Task{assignee_id: assignee})

  defp targets(transition, nil), do: transition |> Enum.map(& &1.agent_id) |> Enum.uniq()

  defp targets(transition, feedback),
    do: (transition ++ feedback.items) |> Enum.map(& &1.agent_id) |> Enum.uniq()

  # Agents (external ones too: they are locked, but get no result) and
  # squads, as `%{id => leader_id | nil}`.
  defp agent_ids(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Repo.all(
        from(a in Actor,
          left_join: s in Squad,
          on: s.actor_id == a.id,
          where: a.id in ^ids and a.kind in [:agent, :squad],
          select: {a.id, s.leader_agent_id}
        )
      )
      |> Map.new()
    end
  end

  ## Running

  @doc """
  Runs the plan of a transition after it was written: the transition's
  own triggers, with `entry` (the reason, nil: none) as their feedback,
  then the triggers of the reason. `task` is the task after the write.
  Returns both lists of outcomes.
  """
  @spec run_transition(Scope.t(), plan(), Task.t(), Entry.t() | nil) ::
          {[Outcome.t()], [Outcome.t()]}
  def run_transition(%Scope{} = scope, plan, %Task{} = task, entry) do
    feedback_id = entry && entry.id
    {own, task} = fire_all(scope, task, plan.transition, feedback_id)
    {own, run_feedback(scope, plan, task, entry)}
  end

  @doc """
  Runs the plan of a feedback write after `entry` was inserted; `task` is
  the task after the write (its `open_question` decides `answer`).

  Options: `steer: {agent_id, run_id}` — the triggers for that agent wait
  for the run they were sent into (`steer_run_id` on the trigger and the
  outcome; `add-run-steering` decision 3, step 4).
  """
  @spec run_feedback(Scope.t(), plan(), Task.t(), Entry.t() | nil, keyword()) :: [Outcome.t()]
  def run_feedback(scope, plan, task, entry, opts \\ [])
  def run_feedback(_scope, %{feedback: nil}, _task, _entry, _opts), do: []
  def run_feedback(_scope, _plan, _task, nil, _opts), do: []

  def run_feedback(scope, %{feedback: %{items: items}}, task, %Entry{} = entry, opts) do
    items =
      items
      |> Enum.reject(&(&1.kind == :answer and task.open_question))
      |> Enum.map(&steer_item(&1, opts[:steer]))

    {outcomes, _task} = fire_all(scope, task, items, entry.id)
    outcomes
  end

  defp steer_item(%{agent_id: id} = item, {id, run_id}), do: Map.put(item, :steer_run_id, run_id)
  defp steer_item(item, _steer), do: item

  # A refused trigger chain leaves a system comment on the task
  # (`Helmsman.Runs.check_chain/3`), which moves its feedback counters: the
  # next target, and the reason's triggers after the transition's, get the
  # task as written (its row is locked by this transaction).
  defp fire_all(scope, task, items, feedback_id) do
    {outcomes, task} =
      Enum.map_reduce(items, task, fn item, task ->
        outcome = fire(scope, task, item, feedback_id)
        {outcome, if(is_nil(outcome), do: task, else: Repo.reload!(task))}
      end)

    {Enum.reject(outcomes, &is_nil/1), task}
  end

  # The target's actor and profile rows are locked (Targets.with_locked/4),
  # with a squad's rows.
  defp fire(scope, task, item, feedback_id) do
    agent = Repo.get!(Actor, item.agent_id)
    profile = Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id))

    cond do
      agent.kind == :squad -> scope |> fire_squad(task, item, agent, feedback_id) |> steered(item)
      is_nil(profile) -> nil
      item.kind == :requested and not profile.wake_on_requested -> nil
      true -> scope |> enqueue(task, item, {agent, profile}, feedback_id) |> steered(item)
    end
  end

  defp steered(outcome, %{steer_run_id: id}), do: %{outcome | steer_run_id: id}
  defp steered(outcome, _item), do: outcome

  defp fire_squad(scope, task, item, squad_actor, feedback_id) do
    loaded = Squads.load(Squads.by_actor_id(squad_actor.id))

    trigger = %{
      kind: item.kind,
      instructions: nil,
      feedback_id: feedback_id,
      extra: Map.merge(item.extra, steer_extra(item))
    }

    case item.kind do
      :mention ->
        SquadDispatch.enqueue(Origin.from_scope(scope), loaded, task, trigger, lane: :reply)

      kind when kind in [:reopen, :resubmit] ->
        case Repo.get_by(TaskGrant, task_id: task.id, agent_id: squad_actor.id, kind: :assign) do
          nil ->
            SquadDispatch.skipped(loaded, kind, :no_grant)

          grant ->
            origin =
              inherit(scope, grant.root_initiator_user_id, grant.causal_agent_ids, loaded.leader)

            SquadDispatch.enqueue(origin, loaded, task, trigger, lane: :work)
        end
    end
  end

  defp enqueue(scope, task, item, {agent, profile}, feedback_id) do
    case source(scope, task, item, agent) do
      {:ok, origin, lane, extra, squad_id} ->
        if lane == :work and task.status in @closed do
          Outcome.skipped(agent, item.kind, :task_closed)
        else
          trigger = %{
            kind: item.kind,
            instructions: nil,
            feedback_id: feedback_id,
            extra: item.extra |> Map.merge(extra) |> Map.merge(steer_extra(item))
          }

          target = %{agent: agent, profile: profile, task: task, lane: lane}
          enqueue_as(origin, target, squad_id, trigger)
        end

      {:skip, reason} ->
        Outcome.skipped(agent, item.kind, reason)
    end
  end

  defp enqueue_as(origin, target, nil, trigger) do
    {:ok, outcome} = Runs.enqueue(origin, target, trigger)
    outcome
  end

  defp enqueue_as(origin, target, squad_id, trigger),
    do: SquadDispatch.enqueue_as(origin, target, squad_id, trigger)

  defp steer_extra(%{steer_run_id: id}), do: %{"steer_run_id" => id}
  defp steer_extra(_item), do: %{}

  defp source(_scope, %Task{status: status}, %{kind: :requested}, _agent)
       when status in @closed,
       do: {:skip, :task_closed}

  defp source(scope, task, %{kind: kind}, agent) when kind in [:reopen, :resubmit, :requested] do
    grant_kind = if kind == :requested, do: :requested, else: :assign

    case Repo.get_by(TaskGrant, task_id: task.id, agent_id: agent.id, kind: grant_kind) do
      nil ->
        {:skip, :no_grant}

      grant ->
        {:ok, inherit(scope, grant.root_initiator_user_id, grant.causal_agent_ids, agent), :work,
         %{}, grant.squad_id}
    end
  end

  # `add-squads` decision 10: the answer records what the question's run
  # was bound to (`bound_assignee_id`), and runs as its squad, if any.
  defp source(scope, _task, %{kind: :answer, question: question}, agent) do
    case question.source_run_id && Repo.get(Run, question.source_run_id) do
      %Run{} = run ->
        bound = if run.lane == :work, do: bound_actor_id(Triggers.run_bound(run))
        origin = inherit(scope, run.root_initiator_user_id, run.causal_agent_ids, agent)
        extra = %{"question_id" => question.id, "assignee_bound" => not is_nil(bound)}
        extra = if bound, do: Map.put(extra, "bound_assignee_id", bound), else: extra
        {:ok, origin, run.lane, extra, run.squad_id}

      _none ->
        {:skip, :no_grant}
    end
  end

  defp source(scope, _task, %{kind: :mention}, _agent),
    do: {:ok, Origin.from_scope(scope), :reply, %{}, nil}

  defp bound_actor_id(nil), do: nil
  defp bound_actor_id({:actor, id}), do: id

  defp bound_actor_id({:squad, squad_id}),
    do: Repo.one(from(s in Squad, where: s.id == ^squad_id, select: s.actor_id))

  defp inherit(scope, initiator, chain, agent) do
    %Origin{
      by_actor_id: scope.actor.id,
      initiator_user_id: initiator,
      chain: Enum.reject(chain, &(&1 == agent.id))
    }
  end
end

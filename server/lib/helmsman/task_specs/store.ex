defmodule Helmsman.TaskSpecs.Store do
  @moduledoc """
  The write plumbing of `Helmsman.TaskSpecs` (`add-spec-workflow`
  decisions 2, 6, 13, 22).

  A write works on a context `%{task, spec, state, initial, attention}`:
  the locked task and spec rows and the `Helmsman.TaskSpecs.State` read
  from them. Insert-only records (versions, requests, reviews, issues,
  notes) are inserted by the write itself; every change of the mutable
  state is an event appended with `append/3`, which applies it to the
  state. `persist/1` then saves the spec row (with the status the state
  gives) and the requests whose state changed, and registers the
  broadcasts that run after the commit.

  The spec row is only ever locked after the task row (designs/01 §4:
  … → task row → spec row → …).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task
  alias Helmsman.TaskSpecs.{Event, Review, ReviewRequest, Spec, State}

  @type ctx :: %{
          task: Task.t(),
          spec: Spec.t(),
          state: State.t(),
          initial: State.t(),
          initial_status: Spec.status() | nil,
          attention: boolean()
        }

  @doc "Locks the spec row of the locked `task` (`FOR UPDATE`); nil when it has none."
  @spec lock(Task.t()) :: Spec.t() | nil
  def lock(%Task{id: task_id}),
    do: Repo.one(from(s in Spec, where: s.task_id == ^task_id, lock: "FOR UPDATE"))

  @doc "The write context of a locked spec."
  @spec context(Task.t(), Spec.t()) :: ctx()
  def context(%Task{} = task, %Spec{} = spec) do
    state = state(spec)

    %{
      task: task,
      spec: spec,
      state: state,
      initial: state,
      initial_status: spec.status,
      attention: false
    }
  end

  # The state of the spec row: the closed requests do not matter to what
  # follows (an event only ever closes a `requested` one).
  defp state(%Spec{} = spec) do
    requests =
      Repo.all(
        from(r in ReviewRequest,
          join: v in assoc(r, :version),
          where: r.spec_id == ^spec.id and r.status == :requested,
          select: {r.number, v.number}
        )
      )
      |> Map.new(fn {n, version} ->
        {n, %{version: version, status: :requested, close_reason: nil, review: nil}}
      end)

    proposal =
      spec.proposal_version &&
        %{
          version: spec.proposal_version,
          summary: spec.proposal_summary,
          by_id: spec.proposal_by_id,
          run_id: spec.proposal_run_id,
          at: spec.proposed_at
        }

    %{
      change_id: spec.change_id,
      latest_version: spec.latest_version,
      final_version: spec.final_version,
      proposal: proposal,
      abandoned: spec.status == :abandoned,
      requests: requests
    }
  end

  @doc """
  Creates the spec of the locked `task` with `change_id` and its `created`
  event (not yet persisted). The task row lock serializes creations, so
  the spec does not exist yet.
  """
  @spec create(Scope.t(), Task.t(), String.t()) :: ctx()
  def create(%Scope{} = scope, %Task{} = task, change_id) do
    now = DateTime.utc_now()

    spec =
      Repo.insert!(%Spec{
        workspace_id: task.workspace_id,
        task_id: task.id,
        change_id: change_id,
        created_by_id: scope.actor.id,
        inserted_at: now,
        updated_at: now
      })

    task
    |> context(spec)
    |> Map.put(:initial_status, nil)
    |> append(scope, [{"created", nil, %{"change_id" => change_id}}])
  end

  @doc """
  Appends events `{action, version, data}` in order, numbered after the
  spec's last, by `scope`'s identity (and run), and applies them.
  """
  @spec append(ctx(), Scope.t() | {pos_integer(), pos_integer() | nil}, [
          {String.t(), pos_integer() | nil, map()}
        ]) :: ctx()
  def append(ctx, %Scope{actor: actor, run: run}, events),
    do: append(ctx, {actor.id, run && run.id}, events)

  def append(ctx, {actor_id, run_id}, events) do
    now = DateTime.utc_now()

    Enum.reduce(events, ctx, fn {action, version, data}, ctx ->
      number = ctx.spec.event_seq + 1

      event = %Event{
        workspace_id: ctx.spec.workspace_id,
        spec_id: ctx.spec.id,
        number: number,
        actor_id: actor_id,
        source_run_id: run_id,
        action: action,
        version: version,
        data: data,
        inserted_at: now
      }

      Repo.insert!(event)

      %{
        ctx
        | spec: %{ctx.spec | event_seq: number},
          state: State.apply_event(ctx.state, Map.from_struct(event))
      }
    end)
  end

  @doc """
  Saves the context: the spec row (state, status, sequence numbers, lock
  version) and the requests whose state changed, then registers
  `{:spec_changed, task_id}` on `task:<id>` and, when the status entered
  or left `pending_approval` or `ctx.attention` is set,
  `{:spec_attention_changed, workspace_id}` on `workspace:<id>`. Returns
  the saved spec.
  """
  @spec persist(ctx()) :: Spec.t()
  def persist(ctx) do
    %{spec: spec, state: state} = ctx
    status = State.status(state)
    proposal = state.proposal || %{}
    now = DateTime.utc_now()

    fields = [
      change_id: state.change_id,
      status: status,
      latest_version: state.latest_version,
      final_version: state.final_version,
      proposal_version: proposal[:version],
      proposal_summary: proposal[:summary],
      proposal_by_id: proposal[:by_id],
      proposal_run_id: proposal[:run_id],
      proposed_at: proposal[:at],
      request_seq: spec.request_seq,
      review_seq: spec.review_seq,
      event_seq: spec.event_seq,
      lock_version: spec.lock_version + 1,
      updated_at: now
    ]

    {1, _} = Repo.update_all(from(s in Spec, where: s.id == ^spec.id), set: fields)
    save_requests(ctx, now)

    Events.after_commit_once(
      {:spec, spec.task_id},
      Events.topic(:task, spec.task_id),
      {:spec_changed, spec.task_id}
    )

    if ctx.attention or status == :pending_approval != (ctx.initial_status == :pending_approval) do
      Events.after_commit_once(
        {:spec_attention, spec.workspace_id},
        Events.topic(:workspace, spec.workspace_id),
        {:spec_attention_changed, spec.workspace_id}
      )
    end

    struct(spec, fields)
  end

  defp save_requests(ctx, now) do
    changed =
      for {n, request} <- ctx.state.requests,
          Map.get(ctx.initial.requests, n) not in [nil, request],
          do: {n, request}

    review_ids = review_ids(ctx.spec.id, for({_n, %{review: r}} <- changed, r, do: r))

    Enum.each(changed, fn {n, request} ->
      Repo.update_all(
        from(r in ReviewRequest, where: r.spec_id == ^ctx.spec.id and r.number == ^n),
        set: [
          status: request.status,
          close_reason: request.close_reason,
          review_id: request.review && review_ids[request.review],
          closed_at: if(request.status == :requested, do: nil, else: now)
        ]
      )
    end)
  end

  defp review_ids(_spec_id, []), do: %{}

  defp review_ids(spec_id, numbers) do
    Repo.all(
      from(r in Review,
        where: r.spec_id == ^spec_id and r.number in ^numbers,
        select: {r.number, r.id}
      )
    )
    |> Map.new()
  end

  @doc "Whether `actor` is a person whose requests are listed in their to-do (`attention/1`)."
  @spec human?(Actor.t()) :: boolean()
  def human?(%Actor{kind: :human}), do: true
  def human?(_actor), do: false
end

defmodule Helmsman.Autopilots.Fire do
  @moduledoc """
  Firing an autopilot (`add-autopilots` decision 6): a scheduled time, a
  manual "run now" or a webhook delivery becomes one record, and maybe a
  task or a run.

  Accepting a scheduled or webhook request reads the autopilot without a
  lock to learn its authorization source, then:

    * a member → a write transaction as that person (maintenance lock
      shared, their membership row `FOR SHARE`), then the autopilot row
      `FOR UPDATE`; a different authorization source under the lock, or
      the person no longer a member, starts over;
    * nobody, or no longer a member → a transaction with the maintenance
      lock only, the autopilot row `FOR UPDATE`, and only when the same
      source and the preconditions still hold, `failed / initiator_left`
      and the autopilot disabled; otherwise it starts over.

  At most #{3} rounds. Under the lock the started record is settled in
  place, a pending one is superseded by the new request, then the request
  is skipped (`overlap`), queued (`pending`) or executed (`started`).
  A queued request is started later (`start_pending/1`) with its own
  initiator and frozen configuration.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Autopilots.{Autopilot, Clock, Content, Record, Settle, State, Target}
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome}
  alias Helmsman.Tasks
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  @rounds 3
  @late_seconds 3600
  @disabling [:unauthorized, :initiator_left, :agent_archived, :project_archived]
  @trigger_roles [:owner, :admin, :member]

  @type request ::
          {:schedule, DateTime.t()}
          | {:webhook, binary(), String.t() | nil, term()}
          | {:manual, String.t() | nil}

  @type result ::
          {:ok, Record.t()}
          | {:ok, :noop}
          | {:ok, {:duplicate, Record.t()}}
          | {:error, :unauthorized | :disabled | :busy | :not_found}

  ## Scheduled and webhook requests

  @doc """
  Accepts a scheduled (`{:schedule, at}`) or webhook (`{:webhook,
  token_hash, delivery_id, payload}`) request for the autopilot `id`.
  """
  @spec request(pos_integer(), request()) :: result()
  def request(id, request), do: accept(id, request, 1)

  defp accept(_id, _request, round) when round > @rounds, do: {:error, :busy}

  defp accept(id, request, round) do
    case Repo.get(Autopilot, id) do
      nil ->
        gone(request)

      autopilot ->
        source = autopilot.initiator_user_id
        test_hook({:read, request_kind(request)})

        autopilot.workspace_id
        |> as_source(source, &accept_locked(&1, autopilot.workspace_id, id, source, request))
        |> accepted(id, request, round)
    end
  end

  defp accepted({:error, :retry}, id, request, round), do: accept(id, request, round + 1)

  defp accepted({:error, {:retry, _cause}}, id, request, round),
    do: accept(id, request, round + 1)

  # Write transaction: the source is no longer a member.
  defp accepted({:error, :not_found}, id, request, round), do: accept(id, request, round + 1)
  defp accepted({:error, :gone}, _id, request, _round), do: gone(request)
  defp accepted({:ok, {:refused, reason}}, _id, _request, _round), do: {:error, reason}
  defp accepted(other, _id, _request, _round), do: other

  # A write transaction as `user_id` when they are a member (maintenance
  # lock, their membership row FOR SHARE), else one with the maintenance
  # lock only; `fun` gets the scope or nil.
  defp as_source(ws, user_id, fun) do
    case member_scope(ws, user_id) do
      {:ok, scope} ->
        Workspaces.write_transaction(scope, :view_workspace, nil, fun)

      :none ->
        Tx.run(
          fn ->
            Locks.maint_shared!(ws)
            fun.(nil)
          end,
          retry: 1
        )
    end
  end

  defp gone({:schedule, _at}), do: {:ok, :noop}
  defp gone(_request), do: {:error, :unauthorized}

  defp accept_locked(scope, ws, id, source, request) do
    test_hook({:accept, request_kind(request)})

    with %Autopilot{} = autopilot <- State.lock(ws, id) || {:error, :gone},
         :ok <- test_hook({:locked, request_kind(request)}),
         :ok <- same_source(autopilot, source),
         :ok <- precondition(autopilot, request) do
      if scope,
        do: decide(autopilot, request, scope, source),
        else: source_left(autopilot, request, source)
    end
  end

  defp same_source(%Autopilot{initiator_user_id: source}, source), do: :ok
  defp same_source(_autopilot, _source), do: {:error, :retry}

  defp precondition(%Autopilot{} = a, {:schedule, at}) do
    if (a.enabled and a.next_run_at) && DateTime.compare(a.next_run_at, at) == :eq,
      do: :ok,
      else: {:ok, :noop}
  end

  defp precondition(%Autopilot{} = a, {:webhook, hash, delivery_id, _payload}) do
    cond do
      is_nil(a.webhook_token_hash) or not Plug.Crypto.secure_compare(a.webhook_token_hash, hash) ->
        {:error, :unauthorized}

      not a.enabled ->
        {:error, :disabled}

      record = delivery_id && Repo.get_by(Record, autopilot_id: a.id, delivery_id: delivery_id) ->
        {:ok, {:duplicate, record}}

      true ->
        :ok
    end
  end

  # The authorization source is gone: the request fails and disables the
  # autopilot (the lock and the preconditions were checked again).
  defp source_left(autopilot, request, source) do
    now = Clock.now()

    record =
      State.insert_record!(
        Map.merge(base_attrs(autopilot, request, source, now), %{
          status: :started,
          started_at: now
        })
      )

    {_autopilot, record} =
      State.finish!(autopilot, record, :failed, :initiator_left, disable: :initiator_left)

    {:ok, record}
  end

  ## Manual

  @doc """
  "Run now" by `scope` (decision 6): member and above who may trigger the
  target, whether the autopilot is enabled or not; `note` (≤ 4 KB) goes
  into the prompt or the task body. The scope's user is the authorization
  source of this trigger.
  """
  @spec manual(Scope.t(), pos_integer(), String.t() | nil) ::
          {:ok, Record.t()} | {:error, :forbidden | :not_found | :busy}
  def manual(%Scope{} = scope, id, note) do
    Workspaces.write_transaction(scope, :manage_autopilots, nil, fn scope ->
      test_hook({:accept, :manual})

      with %Autopilot{} = autopilot <- State.lock(scope.workspace.id, id) || {:error, :not_found},
           :ok <- test_hook({:locked, :manual}),
           target = Target.load(autopilot.agent_id),
           may? = target != nil and Target.may_trigger?(target, scope.user.id, scope.role),
           :ok <- Policy.authorize(scope, :manage_autopilots, %{op: :manage, may_trigger: may?}) do
        decide(autopilot, {:manual, note}, scope, scope.user.id)
      end
    end)
    |> case do
      {:ok, {:refused, reason}} -> {:error, reason}
      {:error, {:retry, _}} -> {:error, :busy}
      other -> other
    end
  end

  ## Deciding (steps 3-6)

  defp decide(autopilot, request, scope, source) do
    now = Clock.now()

    case request do
      {:schedule, at} ->
        if DateTime.diff(now, at) > @late_seconds,
          do: missed(autopilot, at, source, now),
          else: decide_now(autopilot, request, scope, source, now)

      _ ->
        decide_now(autopilot, request, scope, source, now)
    end
  end

  defp missed(autopilot, at, source, now) do
    record =
      State.insert_record!(
        Map.merge(base_attrs(autopilot, {:schedule, at}, source, now), %{
          status: :skipped,
          reason: "missed",
          finished_at: now
        })
      )

    State.reschedule!(autopilot, latest(now, at))
    {:ok, record}
  end

  defp decide_now(autopilot, request, scope, source, now) do
    autopilot = Settle.settle_locked(autopilot)
    %{started: started, pending: pending} = State.open_records(autopilot.id)

    cond do
      # Settling just disabled it: no new work from the schedule or a
      # webhook.
      not autopilot.enabled and elem(request, 0) == :webhook ->
        {:ok, {:refused, :disabled}}

      not autopilot.enabled and elem(request, 0) == :schedule ->
        {:ok, :noop}

      true ->
        if pending, do: supersede!(pending, now)
        attrs = base_attrs(autopilot, request, source, now)
        result = place(autopilot, attrs, started, scope, now)
        advance(autopilot, request, now)
        result
    end
  end

  defp place(autopilot, attrs, %Record{} = started, _scope, now) do
    case autopilot.overlap do
      :skip ->
        {:ok,
         State.insert_record!(
           Map.merge(attrs, %{
             status: :skipped,
             reason: "overlap",
             result: "autopilot run #{started.id} is in progress",
             finished_at: now
           })
         )}

      :queue ->
        {:ok, State.insert_record!(Map.put(attrs, :status, :pending))}
    end
  end

  defp place(autopilot, attrs, nil, scope, now) do
    record = State.insert_record!(Map.merge(attrs, %{status: :started, started_at: now}))
    execute(autopilot, record, scope)
  end

  defp supersede!(pending, now) do
    pending
    |> Changeset.change(status: :skipped, reason: "superseded", finished_at: now)
    |> Repo.update!()
    |> State.notify_record()
  end

  # The scheduled trigger plans the next one from now (never catching up).
  defp advance(autopilot, {:schedule, at}, now) do
    autopilot = Repo.reload!(autopilot)
    State.reschedule!(autopilot, latest(now, at))
  end

  defp advance(_autopilot, _request, _now), do: :ok

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp base_attrs(autopilot, request, source, now) do
    {kind, extra} =
      case request do
        {:schedule, at} ->
          {:schedule, %{scheduled_for: at}}

        {:manual, note} ->
          {:manual, %{note: blank_nil(note)}}

        {:webhook, _hash, delivery_id, payload} ->
          {:webhook, %{delivery_id: delivery_id, payload: payload}}
      end

    Map.merge(
      %{
        workspace_id: autopilot.workspace_id,
        autopilot_id: autopilot.id,
        source: kind,
        initiator_user_id: source,
        config: State.snapshot(autopilot),
        inserted_at: now,
        updated_at: now
      },
      extra
    )
  end

  defp blank_nil(note) when note in [nil, ""], do: nil
  defp blank_nil(note), do: note

  ## Starting a queued request

  @doc """
  Starts the queued record `record_id` (decision 6, "pending"): with its
  own initiator and frozen configuration, in the lock order membership
  row → autopilot row, only while it is still pending and nothing is
  started. An initiator who is no longer valid fails it and disables the
  autopilot only when they are still its authorization source; otherwise
  the record alone is `cancelled`.
  """
  @spec start_pending(pos_integer()) :: {:ok, Record.t() | :noop} | {:error, :busy}
  def start_pending(record_id), do: start_pending(record_id, 1)

  defp start_pending(_record_id, round) when round > @rounds, do: {:error, :busy}

  defp start_pending(record_id, round) do
    case Repo.get(Record, record_id) do
      %Record{status: :pending} = record ->
        record.workspace_id
        |> as_source(record.initiator_user_id, &pending_locked(&1, record))
        |> case do
          {:error, :not_found} -> start_pending(record_id, round + 1)
          {:error, {:retry, _}} -> start_pending(record_id, round + 1)
          other -> other
        end

      _other ->
        {:ok, :noop}
    end
  end

  defp pending_locked(scope, %Record{} = snapshot) do
    test_hook({:start_pending, snapshot.id})

    with %Autopilot{} = autopilot <-
           State.lock(snapshot.workspace_id, snapshot.autopilot_id) || {:ok, :noop},
         %Record{status: :pending} = record <- Repo.get(Record, snapshot.id) || {:ok, :noop},
         %{started: nil} <- State.open_records(autopilot.id) do
      case foreign_refusal(autopilot, record) do
        nil ->
          now = Clock.now()

          record =
            record
            |> Changeset.change(status: :started, started_at: now)
            |> Repo.update!()
            |> State.notify_record()

          execute(autopilot, record, scope)

        reason ->
          {:ok, State.cancel!(record, reason)}
      end
    else
      %Record{} -> {:ok, :noop}
      %{started: %Record{}} -> {:ok, :noop}
      other -> other
    end
  end

  # A queued request whose initiator is no longer the autopilot's source
  # and no longer valid is only cancelled.
  defp foreign_refusal(%Autopilot{initiator_user_id: source}, %Record{initiator_user_id: source}),
    do: nil

  defp foreign_refusal(_autopilot, %Record{} = record) do
    role = Target.role_of(record.workspace_id, record.initiator_user_id)
    target = Target.load(record.config["agent_id"])

    cond do
      is_nil(role) ->
        :initiator_left

      target != nil and not Target.may_trigger?(target, record.initiator_user_id, role) ->
        :unauthorized

      true ->
        nil
    end
  end

  ## Executing (step 5)

  defp execute(autopilot, record, scope) do
    config = record.config
    target = Target.load(config["agent_id"])

    case refusal(record, target, scope) do
      nil ->
        case config["mode"] do
          "create_task" -> create_task(autopilot, record, scope, target)
          "run_only" -> run_only(autopilot, record, scope, target)
        end

      reason ->
        fail(autopilot, record, reason)
    end
  end

  defp refusal(record, target, scope) do
    user_id = record.initiator_user_id
    role = Target.role_of(record.workspace_id, user_id)

    cond do
      is_nil(role) or is_nil(scope) ->
        :initiator_left

      role not in @trigger_roles ->
        :unauthorized

      true ->
        case Target.check(target, user_id, role) do
          :ok -> project_refusal(record.config)
          {:error, reason} -> reason
        end
    end
  end

  defp project_refusal(%{"mode" => "create_task", "project_id" => id}) do
    case id && Repo.get(Project, id) do
      %Project{archived_at: nil} -> nil
      _ -> :project_archived
    end
  end

  defp project_refusal(_config), do: nil

  defp fail(autopilot, record, reason) do
    disable = if reason in @disabling, do: reason
    {_autopilot, record} = State.finish!(autopilot, record, :failed, reason, disable: disable)
    {:ok, record}
  end

  defp create_task(autopilot, record, scope, target) do
    config = record.config
    project = Repo.get!(Project, config["project_id"])
    at = record.scheduled_for || record.inserted_at

    attrs = %{
      title:
        Content.title(
          config["title_template"],
          config["name"],
          record.source,
          at,
          config["timezone"]
        ),
      description:
        Content.task_body(%{
          name: config["name"],
          instructions: config["instructions"],
          source: record.source,
          at: at,
          timezone: config["timezone"],
          note: record.note,
          note_by: user_name(record.workspace_id, record.initiator_user_id),
          payload: record.payload
        }),
      labels: ["autopilot"],
      assignee: target.actor.name,
      start: true
    }

    case Tasks.create(scope, project.key, attrs) do
      {:ok, task} ->
        record =
          record |> Changeset.change(task_id: task.id) |> Repo.update!() |> State.notify_record()

        dispatched(autopilot, record, List.first(task.dispatch || []))

      # Nested in this transaction, an error rolls it all back: the
      # request starts over and sees the cause (an archived project).
      {:error, reason} ->
        {:error, {:retry, reason}}
    end
  end

  defp run_only(autopilot, record, scope, target) do
    {actor, _profile} = Target.runner(target)
    actor = Repo.one!(from(a in Actor, where: a.id == ^actor.id, lock: "FOR SHARE"))

    profile =
      Repo.one!(from(p in AgentProfile, where: p.actor_id == ^actor.id, lock: "FOR SHARE"))

    trigger = %{
      kind: :autopilot,
      instructions: nil,
      extra: %{
        "autopilot_id" => autopilot.id,
        "autopilot_run_id" => record.id,
        "source" => Atom.to_string(record.source),
        "create_tasks" => record.config["create_tasks"] == true
      }
    }

    {:ok, outcome} =
      Runs.enqueue(
        Origin.from_scope(scope),
        %{agent: actor, profile: profile, task: nil},
        trigger
      )

    dispatched(autopilot, record, outcome)
  end

  defp dispatched(_autopilot, record, %Outcome{result: result, run_id: run_id})
       when result in [:queued, :merged, :deferred] do
    {:ok, record |> Changeset.change(run_id: run_id) |> Repo.update!() |> State.notify_record()}
  end

  defp dispatched(autopilot, record, %Outcome{result: :skipped, reason: reason}),
    do: fail(autopilot, record, reason)

  defp dispatched(autopilot, record, nil), do: fail(autopilot, record, :unauthorized)

  ## Helpers

  # The scope of `user_id` acting through the web (decision 4), when a
  # member of the workspace.
  defp member_scope(_ws, nil), do: :none

  defp member_scope(ws, user_id) do
    with %Membership{} <- Repo.get_by(Membership, workspace_id: ws, user_id: user_id),
         %Actor{} = actor <-
           Repo.one(
             from(a in Actor,
               where: a.workspace_id == ^ws and a.user_id == ^user_id and a.kind == :human
             )
           ) do
      {:ok,
       %Scope{
         user: Repo.get!(User, user_id),
         workspace: Repo.get!(Workspace, ws),
         actor: actor,
         via: :web
       }}
    else
      _ -> :none
    end
  end

  defp user_name(_ws, nil), do: nil

  defp user_name(ws, user_id),
    do:
      Repo.one(
        from(a in Actor,
          where: a.workspace_id == ^ws and a.user_id == ^user_id and a.kind == :human,
          select: a.name
        )
      )

  defp request_kind(request), do: elem(request, 0)

  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) ->
          hook.(point)
          :ok

        _ ->
          :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end

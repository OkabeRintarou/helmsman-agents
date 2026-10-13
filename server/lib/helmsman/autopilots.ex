defmodule Helmsman.Autopilots do
  @moduledoc """
  Autopilots (designs/16 §2, `add-autopilots`): an agent (or, creating
  tasks, a squad) started on a cron schedule, by "run now" or by a webhook,
  either creating a task (`create_task`) or running without one
  (`run_only`).

  Writes lock, in the global order of designs/01 §4 (decision 2): the
  maintenance lock (shared), the membership row, the autopilot rows
  (ascending id), then the target's identity and profile or squad rows
  `FOR SHARE`. The last person who saved an autopilot is its
  authorization source (decision 4). Every change is announced on
  `topic/1` after the commit: `{:autopilot, id}` and `{:autopilot_run,
  autopilot_id, record_id}`.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor

  alias Helmsman.Autopilots.{
    Autopilot,
    Clock,
    Content,
    Fire,
    Form,
    Record,
    Schedule,
    Settle,
    State,
    Target,
    Views
  }

  alias Helmsman.Autopilots.Workers.Settle, as: SettleJob
  alias Helmsman.Autopilots.Workers.Sweep
  alias Helmsman.Events
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Workspaces

  @max_per_workspace 100
  @note_bytes 4096
  @token_prefix "hma_"

  @doc "The PubSub topic of the autopilots of a workspace."
  @spec topic(pos_integer()) :: String.t()
  def topic(workspace_id), do: Events.topic(:workspace_autopilots, workspace_id)

  @doc "Limits: autopilots per workspace, and a manual note in UTF-8 bytes."
  @spec limits() :: %{atom() => pos_integer()}
  def limits, do: %{per_workspace: @max_per_workspace, note: @note_bytes, instructions: 16_384}

  ## Reading (decision 12)

  @doc "Every autopilot of the workspace by name (`:view_agents`: viewers too)."
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, :forbidden}
  defdelegate list(scope), to: Views

  @doc """
  The autopilot `id` (`:view_agents`): `%{id, name, agent, project, mode,
  title_template, instructions, create_tasks, cron, timezone, overlap,
  enabled, disabled_reason, next_run_at, webhook, initiator, created_by,
  consecutive_failures, last_run, warnings, permissions, lock_version}`.
  Never the webhook token or its hash.
  """
  @spec get(Scope.t(), pos_integer()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  defdelegate get(scope, id), to: Views

  @doc """
  The records of the autopilot `id`, newest first (`:view_agents`):
  `before_id` and `limit` (default 50, at most 100).
  """
  @spec history(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, :forbidden | :not_found}
  defdelegate history(scope, id, opts \\ []), to: Views

  @doc "One record with its payload, note and frozen configuration (`:view_agents`)."
  @spec get_run(Scope.t(), pos_integer()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  defdelegate get_run(scope, record_id), to: Views

  @doc """
  The next `count` times of `cron` in `timezone` from now, or `{:error,
  changeset}` with the `cron` / `timezone` errors.
  """
  @spec preview(String.t(), String.t(), pos_integer()) ::
          {:ok, [DateTime.t()]} | {:error, Changeset.t()}
  def preview(cron, timezone, count \\ 5) do
    case Schedule.preview(cron, timezone || "UTC", count, Clock.now()) do
      {:ok, times} -> {:ok, times}
      {:error, errors} -> {:error, Form.error_changeset(errors)}
    end
  end

  ## Writing (decisions 1, 3, 4, 5)

  @doc """
  Creates an autopilot as `scope`: member and above who may trigger the
  target. `attrs`: `name`, `agent` (a name), `project` (a key), `mode`,
  `title_template`, `instructions`, `create_tasks`, `cron`, `timezone`,
  `overlap` and `enabled` (default true). The scope's user is its
  authorization source and creator. Returns the view; `{:error,
  changeset}` with every field error; `{:error, :limit_reached}` past
  #{@max_per_workspace} autopilots.
  """
  @spec create(Scope.t(), map()) ::
          {:ok, map()} | {:error, Changeset.t() | :forbidden | :limit_reached}
  def create(%Scope{} = scope, attrs) when is_map(attrs) do
    attrs = Form.normalize(attrs)

    Workspaces.write_transaction(scope, :manage_autopilots, nil, fn scope ->
      ws = scope.workspace.id
      Locks.autopilots!(ws)
      target = Form.lock_target(ws, attrs, nil)
      now = Clock.now()

      with :ok <- authorize_target(scope, target),
           {:ok, changes} <-
             Form.validate(attrs, nil, %{
               target: target,
               project: Form.project(ws, attrs, nil),
               name_taken: name_taken?(ws, attrs.values["name"], nil),
               now: now
             }),
           :ok <- below_limit(ws),
           {:ok, autopilot} <- insert(scope, changes, attrs.enabled != false) do
        autopilot = autopilot |> State.reschedule!(now) |> State.notify()
        {:ok, autopilot.id}
      end
    end)
    |> view(scope)
  end

  defp insert(scope, changes, enabled?) do
    %Autopilot{
      workspace_id: scope.workspace.id,
      initiator_user_id: scope.user.id,
      created_by_user_id: scope.user.id,
      enabled: enabled?
    }
    |> Changeset.change(changes)
    |> name_constraint()
    |> Repo.insert()
  end

  @doc """
  Changes the autopilot `id` (attributes as `create/2`, all optional, but
  `enabled`; `lock_version`: `{:error, :stale}` when not the current one).
  The scope's user becomes its authorization source. Changing the
  execution configuration cancels the queued request (`config_changed`);
  changing the cron or the time zone plans the next time again.
  """
  @spec update(Scope.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, Changeset.t() | :forbidden | :not_found | :stale}
  def update(%Scope{} = scope, id, attrs) when is_map(attrs) do
    attrs = Form.normalize(attrs)

    Workspaces.write_transaction(scope, :manage_autopilots, nil, fn scope ->
      ws = scope.workspace.id

      with %Autopilot{} = current <- State.lock(ws, id) || {:error, :not_found},
           current_target = Target.load(current.agent_id),
           target = Form.lock_target(ws, attrs, current),
           :ok <- authorize_target(scope, current_target),
           :ok <- authorize_target(scope, target),
           :ok <- check_version(current, attrs.lock_version),
           {:ok, changes} <-
             Form.validate(attrs, current, %{
               target: target,
               project: Form.project(ws, attrs, current),
               name_taken: name_taken?(ws, attrs.values["name"], current.id),
               now: Clock.now()
             }),
           {:ok, updated} <-
             current
             |> Changeset.change(Map.put(changes, :initiator_user_id, scope.user.id))
             |> Changeset.force_change(:lock_version, current.lock_version + 1)
             |> name_constraint()
             |> Repo.update() do
        after_update(current, updated)
        {:ok, updated.id}
      end
    end)
    |> view(scope)
  end

  defp after_update(current, updated) do
    %{pending: pending} = State.open_records(updated.id)

    if pending && State.config_changed?(current, updated),
      do: State.cancel!(pending, :config_changed)

    if updated.cron != current.cron or updated.timezone != current.timezone,
      do: State.reschedule!(updated, Clock.now()),
      else: State.notify(updated)
  end

  @doc """
  Disables the autopilot `id` (`manual`, decision 10): admin and above, or
  a member who may trigger its target. The authorization source does not
  change.
  """
  @spec disable(Scope.t(), pos_integer()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  def disable(%Scope{} = scope, id) do
    locked_write(scope, id, :disable, fn autopilot, _scope ->
      State.disable!(autopilot, :manual)
      {:ok, autopilot.id}
    end)
    |> view(scope)
  end

  @doc """
  Enables the autopilot `id`: clears the reason, resets the failure count
  and plans the next time from now (nothing missed is run). The scope's
  user becomes its authorization source.
  """
  @spec enable(Scope.t(), pos_integer()) :: {:ok, map()} | {:error, :forbidden | :not_found}
  def enable(%Scope{} = scope, id) do
    locked_write(scope, id, :manage, fn autopilot, scope ->
      autopilot
      |> Changeset.change(
        enabled: true,
        disabled_reason: nil,
        consecutive_failures: 0,
        initiator_user_id: scope.user.id
      )
      |> Repo.update!()
      |> State.reschedule!(Clock.now())
      |> State.notify()

      {:ok, autopilot.id}
    end)
    |> view(scope)
  end

  @doc """
  Deletes the autopilot `id` after disabling it (decision 10); its records
  go with it, the tasks and runs it started stay.
  """
  @spec delete(Scope.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :forbidden | :not_found}
  def delete(%Scope{} = scope, id) do
    locked_write(scope, id, :disable, fn autopilot, _scope ->
      autopilot = State.disable!(autopilot, :manual)
      Repo.delete!(autopilot)
      State.notify(autopilot)
      {:ok, autopilot.id}
    end)
  end

  @doc """
  "Run now" (decision 6): member and above who may trigger the target,
  enabled or not; `note` (≤ #{@note_bytes} bytes) goes into the prompt or
  the task body. Returns the record.
  """
  @spec run_now(Scope.t(), pos_integer(), String.t() | nil) ::
          {:ok, Record.t()} | {:error, Changeset.t() | :forbidden | :not_found | :busy}
  def run_now(%Scope{} = scope, id, note \\ nil) do
    cond do
      not (is_nil(note) or is_binary(note)) ->
        {:error, Form.error_changeset(note: "is invalid")}

      is_binary(note) and (not String.valid?(note) or byte_size(note) > @note_bytes) ->
        {:error, Form.error_changeset(note: "should be at most #{@note_bytes} bytes")}

      true ->
        Fire.manual(scope, id, note)
    end
  end

  ## Webhooks (decision 14)

  @doc """
  Turns the webhook of the autopilot `id` on with a new token, returned
  once: `{:ok, %{token: token, autopilot: view}}`. The scope's user
  becomes its authorization source.
  """
  @spec enable_webhook(Scope.t(), pos_integer()) ::
          {:ok, %{token: String.t(), autopilot: map()}} | {:error, :forbidden | :not_found}
  def enable_webhook(%Scope{} = scope, id), do: new_token(scope, id)

  @doc "Replaces the webhook token; the old one stops working at once. As `enable_webhook/2`."
  @spec rotate_webhook_token(Scope.t(), pos_integer()) ::
          {:ok, %{token: String.t(), autopilot: map()}} | {:error, :forbidden | :not_found}
  def rotate_webhook_token(%Scope{} = scope, id), do: new_token(scope, id)

  defp new_token(scope, id) do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    locked_write(scope, id, :manage, fn autopilot, scope ->
      autopilot
      |> Changeset.change(webhook_token_hash: hash(token), initiator_user_id: scope.user.id)
      |> Repo.update!()
      |> State.notify()

      {:ok, autopilot.id}
    end)
    |> view(scope)
    |> case do
      {:ok, view} -> {:ok, %{token: token, autopilot: view}}
      error -> error
    end
  end

  @doc "Turns the webhook off; the authorization source does not change."
  @spec disable_webhook(Scope.t(), pos_integer()) ::
          {:ok, map()} | {:error, :forbidden | :not_found}
  def disable_webhook(%Scope{} = scope, id) do
    locked_write(scope, id, :manage, fn autopilot, _scope ->
      autopilot |> Changeset.change(webhook_token_hash: nil) |> Repo.update!() |> State.notify()
      {:ok, autopilot.id}
    end)
    |> view(scope)
  end

  @doc """
  Authenticates a webhook request for the autopilot `id` with the bearer
  `token`: `{:ok, token_hash}`, or `{:error, :unauthorized}` alike for an
  unknown autopilot, one without a webhook and a wrong token. Compares in
  constant time.
  """
  @spec authenticate_webhook(term(), term()) :: {:ok, binary()} | {:error, :unauthorized}
  def authenticate_webhook(id, token) do
    given = if is_binary(token), do: hash(token), else: hash("")

    stored =
      case parse_id(id) do
        nil -> nil
        id -> Repo.one(from(a in Autopilot, where: a.id == ^id, select: a.webhook_token_hash))
      end

    if is_binary(token) and String.starts_with?(token, @token_prefix) and is_binary(stored) and
         Plug.Crypto.secure_compare(given, stored),
       do: {:ok, given},
       else: {:error, :unauthorized}
  end

  @doc """
  Fires the autopilot `id` for an authenticated webhook request: `body`
  stored as decision 9 says. `{:ok, record}`, `{:ok, {:duplicate,
  record}}` for a delivery ID seen before, `{:error, :disabled |
  :unauthorized | :busy}`.
  """
  @spec fire_webhook(
          pos_integer() | String.t(),
          binary(),
          String.t() | nil,
          binary(),
          String.t() | nil
        ) ::
          {:ok, Record.t() | {:duplicate, Record.t()}}
          | {:error, :disabled | :unauthorized | :busy}
  def fire_webhook(id, token_hash, delivery_id, body, content_type) do
    payload = Content.store(body, content_type)

    case Fire.request(parse_id(id), {:webhook, token_hash, delivery_id, payload}) do
      {:ok, :noop} -> {:error, :busy}
      {:error, :not_found} -> {:error, :unauthorized}
      other -> other
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n < 9_223_372_036_854_775_807 -> n
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

  ## Settling (decision 8)

  @doc """
  Settles the started record of the autopilot `id` (decision 8), in a
  transaction of its own. Idempotent.
  """
  @spec settle(pos_integer()) :: {:ok, Autopilot.t() | :gone}
  defdelegate settle(id), to: Settle

  @doc """
  Whether the record of a run-only autopilot `run` still stands
  (decision 11): `:current` while it exists and is `started`, else
  `:ended`; nil for any other run. Reads without a lock.
  """
  @spec record_state(Run.t()) :: :current | :ended | nil
  def record_state(%Run{triggers: triggers}) do
    case Enum.find(triggers, &(&1["kind"] == "autopilot")) do
      nil ->
        nil

      %{"autopilot_run_id" => id} ->
        if Repo.exists?(from(r in Record, where: r.id == ^id and r.status == :started)),
          do: :current,
          else: :ended

      _other ->
        :ended
    end
  end

  @doc """
  The project of a run-only autopilot `run`: the one frozen in its record
  (decision 11; its repository binding as it is now), or nil (no project,
  no record, another kind of run). Reads without a lock.
  """
  @spec run_project(Run.t()) :: Project.t() | nil
  def run_project(%Run{task_id: nil, triggers: triggers}) do
    with %{"autopilot_run_id" => id} <- Enum.find(triggers, &(&1["kind"] == "autopilot")),
         %Record{config: %{"project_id" => project_id}} when is_integer(project_id) <-
           Repo.get(Record, id) do
      Repo.get(Project, project_id)
    else
      _ -> nil
    end
  end

  def run_project(_run), do: nil

  @doc """
  What the prompt of a run-only autopilot `run` needs (decision 11): its
  record and the name of whoever ran it by hand, or nil for any other run.
  """
  @spec prompt_context(Run.t()) :: %{record: Record.t(), note_by: String.t() | nil} | nil
  def prompt_context(%Run{task_id: nil, triggers: triggers}) do
    with %{"autopilot_run_id" => id} <- Enum.find(triggers, &(&1["kind"] == "autopilot")),
         %Record{} = record <- Repo.get(Record, id) do
      name =
        record.initiator_user_id &&
          Repo.one(
            from(a in Actor,
              where:
                a.workspace_id == ^record.workspace_id and a.user_id == ^record.initiator_user_id and
                  a.kind == :human,
              select: a.name
            )
          )

      %{record: record, note_by: name}
    else
      _ -> nil
    end
  end

  def prompt_context(_run), do: nil

  @doc "The protocol version a daemon needs for a run-only run in a repository."
  @spec snapshot_version() :: pos_integer()
  defdelegate snapshot_version(), to: HelmsmanProtocol

  @doc false
  # The runs `runs` ended (`Helmsman.Runs.after_ended/1`, in the
  # transaction that ended them): their autopilots, or the autopilots
  # whose started record is on their task, get a `Settle` job.
  @spec after_runs_ended([Run.t()]) :: :ok
  def after_runs_ended(runs) do
    direct = for run <- runs, id = autopilot_of(run), do: id
    task_ids = for %Run{task_id: id} <- runs, id, uniq: true, do: id
    settle_later(direct ++ started_on_tasks(task_ids))
  end

  @doc false
  # The task changed (a final status, its assignee, an automatic retry
  # that will not happen): its started autopilot records are settled.
  @spec after_task_changed(pos_integer() | nil) :: :ok
  def after_task_changed(nil), do: :ok
  def after_task_changed(task_id), do: settle_later(started_on_tasks([task_id]))

  @doc false
  # A step of `Helmsman.Tasks.TransitionSteps`: a task moved to `done`,
  # `verified`, `rejected` or `cancelled` settles its started records.
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{id: id}, %TaskEvent{to_status: status}, _scope)
      when status in [:done, :verified, :rejected, :cancelled],
      do: after_task_changed(id)

  def after_transition(_task, _event, _scope), do: :ok

  defp autopilot_of(%Run{triggers: triggers}),
    do: Enum.find_value(triggers, &(&1["kind"] == "autopilot" && &1["autopilot_id"]))

  defp started_on_tasks([]), do: []

  defp started_on_tasks(task_ids),
    do:
      Repo.all(
        from(r in Record,
          where: r.task_id in ^task_ids and r.status == :started,
          select: r.autopilot_id
        )
      )

  defp settle_later(ids) do
    for id <- Enum.uniq(ids) do
      {:ok, _job} = Oban.insert(SettleJob.new(%{autopilot_id: id}))
    end

    :ok
  end

  @doc false
  # `Helmsman.Members` removed `user_id` from the workspace (the
  # membership row is locked FOR UPDATE): the autopilots whose
  # authorization source they are are disabled (`initiator_left`), locked
  # by ascending id.
  @spec initiator_left(pos_integer(), pos_integer()) :: :ok
  def initiator_left(workspace_id, user_id) do
    Repo.all(
      from(a in Autopilot,
        where: a.workspace_id == ^workspace_id and a.initiator_user_id == ^user_id,
        order_by: a.id,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(&State.disable!(&1, :initiator_left))
  end

  @doc """
  Inserts one reconciliation of the schedules (decision 5), as after the
  application starts.
  """
  @spec sweep_soon() :: :ok
  def sweep_soon do
    {:ok, _job} = Oban.insert(Sweep.new(%{}))
    :ok
  end

  ## Helpers

  defp locked_write(scope, id, op, fun) do
    Workspaces.write_transaction(scope, :manage_autopilots, nil, fn scope ->
      with %Autopilot{} = autopilot <- State.lock(scope.workspace.id, id) || {:error, :not_found},
           target = Target.load(autopilot.agent_id),
           may? = target != nil and Target.may_trigger?(target, scope.user.id, scope.role),
           :ok <- Policy.authorize(scope, :manage_autopilots, %{op: op, may_trigger: may?}) do
        fun.(autopilot, scope)
      end
    end)
  end

  # Creating or saving: the scope's user may trigger the target. An
  # unknown target is a field error reported by validation.
  defp authorize_target(_scope, nil), do: :ok
  defp authorize_target(_scope, %{profile: nil, squad: nil}), do: :ok

  defp authorize_target(scope, target) do
    may? = Target.may_trigger?(target, scope.user.id, scope.role)
    Policy.authorize(scope, :manage_autopilots, %{op: :manage, may_trigger: may?})
  end

  defp check_version(%Autopilot{lock_version: v}, given) when is_integer(given) and given != v,
    do: {:error, :stale}

  defp check_version(_autopilot, _given), do: :ok

  defp name_taken?(ws, name, except_id) when is_binary(name) do
    query =
      from(a in Autopilot,
        where: a.workspace_id == ^ws and a.name == ^String.trim(name)
      )

    query = if except_id, do: where(query, [a], a.id != ^except_id), else: query
    Repo.exists?(query)
  end

  defp name_taken?(_ws, _name, _except_id), do: false

  defp name_constraint(changeset),
    do:
      Changeset.unique_constraint(changeset, :name,
        name: :autopilots_workspace_id_name_index,
        message: "has already been taken"
      )

  defp below_limit(ws) do
    count = Repo.aggregate(from(a in Autopilot, where: a.workspace_id == ^ws), :count)
    if count < @max_per_workspace, do: :ok, else: {:error, :limit_reached}
  end

  defp view({:ok, id}, scope), do: Views.get(scope, id)

  defp view({:error, %Changeset{errors: errors}}, _scope) do
    {:error, Form.error_changeset(for({field, {msg, _}} <- errors, do: {field, msg}))}
  end

  defp view(error, _scope), do: error
end

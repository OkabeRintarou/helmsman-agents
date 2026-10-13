defmodule Helmsman.Autopilots.Views do
  @moduledoc false
  # Reading autopilots and their records (`add-autopilots` decision 12).

  import Ecto.Query

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Autopilots.{Autopilot, Record, Target}
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  @default_limit 50
  @max_limit 100
  # The protocol version that can check a repository out read-only
  # (decision 13).
  @snapshot_version 6

  @doc "The protocol version a daemon needs for a run-only run in a repository."
  @spec snapshot_version() :: pos_integer()
  def snapshot_version, do: @snapshot_version

  def list(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :view_agents) do
      autopilots =
        Repo.all(
          from(a in Autopilot,
            where: a.workspace_id == ^scope.workspace.id,
            order_by: [asc: fragment("lower(?::text)", a.name), asc: a.id]
          )
        )

      {:ok, Enum.map(autopilots, &view(scope, &1))}
    end
  end

  def get(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, :view_agents),
         %Autopilot{} = autopilot <- fetch(scope, id) do
      {:ok, view(scope, autopilot)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def history(%Scope{} = scope, id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    before_id = Keyword.get(opts, :before_id)

    with :ok <- Policy.authorize(scope, :view_agents),
         %Autopilot{} <- fetch(scope, id) do
      query =
        from(r in Record, where: r.autopilot_id == ^id, order_by: [desc: r.id], limit: ^limit)

      query = if before_id, do: where(query, [r], r.id < ^before_id), else: query
      records = Repo.all(query)
      {:ok, record_views(scope.workspace.id, records)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def get_run(%Scope{} = scope, record_id) do
    with :ok <- Policy.authorize(scope, :view_agents),
         %Record{} = record <-
           Repo.one(
             from(r in Record,
               where: r.id == ^record_id and r.workspace_id == ^scope.workspace.id
             )
           ) do
      [view] = record_views(scope.workspace.id, [record])
      {:ok, Map.merge(view, %{payload: record.payload, note: record.note, config: record.config})}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp fetch(scope, id) when is_integer(id),
    do:
      Repo.one(from(a in Autopilot, where: a.id == ^id and a.workspace_id == ^scope.workspace.id))

  defp fetch(_scope, _id), do: nil

  defp view(scope, %Autopilot{} = a) do
    target = Target.load(a.agent_id)
    project = a.project_id && Repo.get(Project, a.project_id)
    user_id = scope.user && scope.user.id
    may? = target != nil and Target.may_trigger?(target, user_id, scope.role)

    last =
      Repo.one(
        from(r in Record, where: r.autopilot_id == ^a.id, order_by: [desc: r.id], limit: 1)
      )

    %{
      id: a.id,
      name: a.name,
      agent: target && %{name: target.actor.name, kind: Atom.to_string(target.actor.kind)},
      project: project && %{key: project.key, name: project.name},
      mode: a.mode,
      title_template: a.title_template,
      instructions: a.instructions,
      create_tasks: a.create_tasks,
      cron: a.cron,
      timezone: a.timezone,
      overlap: a.overlap,
      enabled: a.enabled,
      disabled_reason: a.disabled_reason,
      next_run_at: a.next_run_at,
      webhook: %{enabled: not is_nil(a.webhook_token_hash), url: webhook_url(a.id)},
      initiator: person(a.workspace_id, a.initiator_user_id),
      created_by: person(a.workspace_id, a.created_by_user_id),
      consecutive_failures: a.consecutive_failures,
      last_run: last && hd(record_views(a.workspace_id, [last])),
      warnings: warnings(a, target, project),
      permissions: %{
        manage: allowed?(scope, :manage, may?),
        run: allowed?(scope, :manage, may?),
        disable: allowed?(scope, :disable, may?)
      },
      lock_version: a.lock_version
    }
  end

  defp allowed?(scope, op, may?),
    do: Policy.authorize(scope, :manage_autopilots, %{op: op, may_trigger: may?}) == :ok

  @doc false
  # Why the next trigger would fail (decision 12).
  def warnings(%Autopilot{} = a, target, project) do
    source_warnings(a, target) ++
      target_warnings(a, target) ++
      project_warnings(a, project) ++ daemon_warnings(a, target, project)
  end

  defp source_warnings(a, target) do
    role = Target.role_of(a.workspace_id, a.initiator_user_id)

    cond do
      is_nil(role) -> [:initiator_left]
      target && not Target.may_trigger?(target, a.initiator_user_id, role) -> [:unauthorized]
      true -> []
    end
  end

  # Whatever the source's access (reported above).
  defp target_warnings(_a, nil), do: [:agent_archived]

  defp target_warnings(a, target) do
    case Target.check(target, a.initiator_user_id, :owner) do
      :ok -> []
      {:error, :unauthorized} -> []
      {:error, reason} -> [reason]
    end
  end

  defp project_warnings(%Autopilot{mode: :create_task}, nil), do: [:project_archived]

  defp project_warnings(%Autopilot{mode: :create_task}, %Project{archived_at: %DateTime{}}),
    do: [:project_archived]

  defp project_warnings(_a, _project), do: []

  defp daemon_warnings(%Autopilot{mode: :run_only}, %{} = target, %Project{} = project)
       when not is_nil(project.repository_id) or not is_nil(project.local_repository_id) do
    {_actor, profile} = Target.runner(target)

    version =
      profile && profile.runtime_id &&
        Repo.one(
          from(r in Runtime,
            join: d in Daemon,
            on: d.id == r.daemon_id,
            where: r.id == ^profile.runtime_id,
            select: d.protocol_version
          )
        )

    if is_integer(version) and version < @snapshot_version, do: [:daemon_too_old], else: []
  end

  defp daemon_warnings(_a, _target, _project), do: []

  defp webhook_url(id),
    do: Application.get_env(:helmsman, :public_url, "") <> "/hooks/autopilots/#{id}"

  defp person(_ws, nil), do: nil

  defp person(ws, user_id) do
    case Repo.one(
           from(a in Actor,
             where: a.workspace_id == ^ws and a.user_id == ^user_id and a.kind == :human,
             select: a.name
           )
         ) do
      nil -> nil
      name -> %{name: name}
    end
  end

  defp record_views(ws, records) do
    task_ids = for %Record{task_id: id} <- records, id, do: id
    idents = Map.new(Repo.all(from(t in Task, where: t.id in ^task_ids, select: {t.id, t.ident})))

    Enum.map(records, fn r ->
      %{
        id: r.id,
        autopilot_id: r.autopilot_id,
        source: r.source,
        status: r.status,
        reason: r.reason,
        result: r.result,
        initiator: person(ws, r.initiator_user_id),
        task: idents[r.task_id],
        run_id: r.run_id,
        delivery_id: r.delivery_id,
        scheduled_for: r.scheduled_for,
        started_at: r.started_at,
        finished_at: r.finished_at,
        inserted_at: r.inserted_at
      }
    end)
  end
end

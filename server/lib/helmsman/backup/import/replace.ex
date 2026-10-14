defmodule Helmsman.Backup.Import.Replace do
  @moduledoc "Deletes task data explicitly while preserving workspace configuration."
  import Ecto.Query
  alias Helmsman.Autopilots.{Autopilot, Clock, Record, State}
  alias Helmsman.Autopilots.Workers.StartPending
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @deletion_tables ~w(tasks task_events feedback task_links task_grants task_pull_requests task_local_branches runs run_events run_tokens run_steers)
  @null_columns [
    {"tasks", "epic_id"},
    {"runs", "retry_of_id"},
    {"autopilot_runs", "task_id"},
    {"autopilot_runs", "run_id"}
  ]
  @deleted_columns [
    {"task_events", "task_id"},
    {"task_events", "feedback_id"},
    {"task_events", "source_run_id"},
    {"feedback", "task_id"},
    {"feedback", "supersedes_id"},
    {"feedback", "superseded_by_id"},
    {"feedback", "source_run_id"},
    {"feedback", "reply_to_seq"},
    {"feedback", "reply_root_seq"},
    {"task_links", "from_task_id"},
    {"task_links", "to_task_id"},
    {"task_grants", "task_id"},
    {"task_pull_requests", "task_id"},
    {"task_local_branches", "task_id"},
    {"run_steers", "run_id"},
    {"run_steers", "feedback_id"},
    {"runs", "task_id"},
    {"run_events", "run_id"},
    {"run_tokens", "run_id"}
  ]
  def deleted_columns, do: @deleted_columns

  @database_null_columns [
    {"agent_designs", "current_run_id"},
    {"agent_design_messages", "run_id"}
  ]
  def database_null_columns, do: @database_null_columns
  def deletion_tables, do: @deletion_tables
  def null_columns, do: @null_columns

  def clear(wid) do
    blocked =
      Repo.query!(
        "SELECT DISTINCT t.ident, 'active_run' FROM runs r JOIN tasks t ON t.id=r.task_id WHERE r.workspace_id=$1 AND r.status IN ('claimed','running','cancelling') UNION SELECT t.ident, 'open_pr' FROM task_pull_requests p JOIN tasks t ON t.id=p.task_id WHERE p.workspace_id=$1 AND p.state IN ('draft','open')",
        [wid]
      ).rows

    if blocked != [] do
      {:error,
       {:replace_blocked,
        Enum.map(blocked, fn [task, reason] -> %{task: task, reason: reason} end)}}
    else
      clear_autopilot_references(wid)
      tasks = "SELECT id FROM tasks WHERE workspace_id=$1"
      runs = "SELECT id FROM runs WHERE workspace_id=$1 AND task_id IS NOT NULL"
      Repo.query!("UPDATE tasks SET epic_id=NULL WHERE workspace_id=$1", [wid])

      Repo.query!(
        "UPDATE feedback SET status='active', supersedes_id=NULL, superseded_by_id=NULL, reply_to_seq=NULL, reply_root_seq=NULL WHERE workspace_id=$1",
        [wid]
      )

      Repo.query!(
        "DELETE FROM run_steers WHERE run_id IN (#{runs}) OR feedback_id IN (SELECT id FROM feedback WHERE workspace_id=$1)",
        [wid]
      )

      for table <-
            ~w(task_links task_events task_grants task_pull_requests task_local_branches feedback) do
        Repo.query!("DELETE FROM #{table} WHERE workspace_id=$1", [wid])
      end

      Repo.query!(
        "WITH locked AS (SELECT id FROM runs WHERE workspace_id=$1 AND retry_of_id IN (#{runs}) ORDER BY id FOR UPDATE) UPDATE runs SET retry_of_id=NULL FROM locked WHERE runs.id=locked.id",
        [wid]
      )

      # Design conversations are retained; their optional historical references are released by the FK.
      Repo.query!("DELETE FROM runs WHERE id IN (#{runs})", [wid])
      Repo.query!("DELETE FROM tasks WHERE id IN (#{tasks})", [wid])
      :ok
    end
  end

  defp clear_autopilot_references(wid) do
    affected =
      from(r in Record,
        left_join: task in Task,
        on: task.id == r.task_id,
        left_join: run in Run,
        on: run.id == r.run_id,
        where:
          r.workspace_id == ^wid and
            (not is_nil(task.id) or not is_nil(run.task_id)),
        select: r.autopilot_id
      )

    autopilots =
      Repo.all(
        from(a in Autopilot,
          where: a.workspace_id == ^wid and a.id in subquery(affected),
          order_by: a.id,
          lock: "FOR UPDATE"
        )
      )

    for autopilot <- autopilots do
      records =
        Repo.all(
          from(r in Record,
            where: r.autopilot_id == ^autopilot.id,
            order_by: r.id,
            lock: "FOR UPDATE"
          )
        )

      Enum.each(records, &clear_autopilot_record(&1, wid))

      %{started: started, pending: pending} = State.open_records(autopilot.id)

      if pending && is_nil(started) do
        # Oban's transaction insert becomes visible to workers only after commit.
        {:ok, _} = Oban.insert(StartPending.new(%{autopilot_run_id: pending.id}))
      end
    end
  end

  defp clear_autopilot_record(record, wid) do
    fields = autopilot_reference_changes(record, wid)

    if fields != %{} do
      record
      |> Ecto.Changeset.change(fields)
      |> Repo.update!()
      |> State.notify_record()
    end
  end

  defp autopilot_reference_changes(record, wid) do
    task? = deleted_task?(record.task_id, wid)
    run? = deleted_run?(record.run_id, wid)

    fields = if task?, do: %{task_id: nil}, else: %{}
    fields = if run?, do: Map.put(fields, :run_id, nil), else: fields

    if task? && record.status == :started do
      Map.merge(fields, %{
        status: :cancelled,
        reason: "task_deleted",
        finished_at: Clock.now()
      })
    else
      fields
    end
  end

  defp deleted_task?(nil, _wid), do: false

  defp deleted_task?(id, wid),
    do:
      Repo.exists?(
        from(t in Task,
          where: t.workspace_id == ^wid and t.id == ^id
        )
      )

  defp deleted_run?(nil, _wid), do: false

  defp deleted_run?(id, wid),
    do:
      Repo.exists?(
        from(r in Run,
          where: r.workspace_id == ^wid and r.id == ^id and not is_nil(r.task_id)
        )
      )
end

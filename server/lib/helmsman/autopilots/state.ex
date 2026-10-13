defmodule Helmsman.Autopilots.State do
  @moduledoc false
  # Writes shared by saving, firing and settling autopilots
  # (`add-autopilots` decisions 5, 8, 10). Every function runs in the
  # caller's transaction with the autopilot row locked `FOR UPDATE`.

  import Ecto.Query

  alias Ecto.Changeset
  alias Helmsman.Autopilots.{Autopilot, Clock, Content, Record, Schedule}
  alias Helmsman.Autopilots.Workers.Fire, as: FireJob
  alias Helmsman.Events
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.Run

  @config_keys ~w(name mode agent_id project_id instructions title_template timezone create_tasks)

  @doc "The topic of a workspace's autopilots."
  @spec topic(pos_integer()) :: String.t()
  def topic(workspace_id), do: Events.topic(:workspace_autopilots, workspace_id)

  @doc "Locks the autopilot `id` of the workspace `FOR UPDATE`; nil when gone."
  @spec lock(pos_integer(), pos_integer()) :: Autopilot.t() | nil
  def lock(workspace_id, id),
    do:
      Repo.one(
        from(a in Autopilot,
          where: a.id == ^id and a.workspace_id == ^workspace_id,
          lock: "FOR UPDATE"
        )
      )

  @doc "The execution configuration of `autopilot` to freeze in a record."
  @spec snapshot(Autopilot.t()) :: map()
  def snapshot(%Autopilot{} = a) do
    %{
      "name" => a.name,
      "mode" => Atom.to_string(a.mode),
      "agent_id" => a.agent_id,
      "project_id" => a.project_id,
      "instructions" => a.instructions,
      "title_template" => a.title_template,
      "timezone" => a.timezone,
      "create_tasks" => a.create_tasks
    }
  end

  @doc "Whether the execution configuration differs between two autopilots."
  @spec config_changed?(Autopilot.t(), Autopilot.t()) :: boolean()
  def config_changed?(a, b),
    do: Map.take(snapshot(a), @config_keys) != Map.take(snapshot(b), @config_keys)

  @doc "The started and pending records of the autopilot."
  @spec open_records(pos_integer()) :: %{started: Record.t() | nil, pending: Record.t() | nil}
  def open_records(autopilot_id) do
    records =
      Repo.all(
        from(r in Record,
          where: r.autopilot_id == ^autopilot_id and r.status in [:started, :pending]
        )
      )

    %{
      started: Enum.find(records, &(&1.status == :started)),
      pending: Enum.find(records, &(&1.status == :pending))
    }
  end

  @doc "Inserts a record; announced after the commit."
  @spec insert_record!(map()) :: Record.t()
  def insert_record!(attrs) do
    record = Repo.insert!(struct!(Record, attrs))
    notify_record(record)
    record
  end

  @doc """
  Ends `record` with `status` and `reason` (and `result`) and applies the
  failure count (decision 8): `failed` adds one and disables the
  autopilot (`consecutive_failures`) at the limit, `succeeded` resets it.
  `disable`: a reason to disable the autopilot with instead. Returns the
  record.
  """
  @spec finish!(Autopilot.t(), Record.t(), atom(), String.t() | atom() | nil, keyword()) ::
          {Autopilot.t(), Record.t()}
  def finish!(%Autopilot{} = autopilot, %Record{} = record, status, reason, opts \\ []) do
    record =
      record
      |> Changeset.change(
        status: status,
        reason: reason && to_string(reason),
        result: truncate(Keyword.get(opts, :result, record.result)),
        finished_at: Clock.now()
      )
      |> Repo.update!()

    notify_record(record)
    {count(autopilot, status, Keyword.get(opts, :disable)), record}
  end

  defp count(autopilot, :failed, disable) do
    failures = autopilot.consecutive_failures + 1

    autopilot =
      autopilot |> Changeset.change(consecutive_failures: failures) |> Repo.update!()

    cond do
      disable ->
        disable!(autopilot, disable)

      failures >= max_failures() and autopilot.enabled ->
        disable!(autopilot, :consecutive_failures)

      true ->
        notify(autopilot)
    end
  end

  defp count(autopilot, :succeeded, _disable) do
    if autopilot.consecutive_failures == 0,
      do: autopilot,
      else: autopilot |> Changeset.change(consecutive_failures: 0) |> Repo.update!() |> notify()
  end

  defp count(autopilot, _status, nil), do: autopilot
  defp count(autopilot, _status, reason), do: disable!(autopilot, reason)

  defp max_failures,
    do:
      :helmsman
      |> Application.get_env(Helmsman.Autopilots, [])
      |> Keyword.get(:max_consecutive_failures, 5)

  @doc """
  Disables the autopilot (decision 10): no schedule, the reason recorded,
  the pending record `cancelled / autopilot_disabled`, a run-only run still
  waiting to be claimed cancelled (`obsolete`) with its record. Claimed
  runs and created tasks are left alone. A disabled autopilot keeps its
  first reason.
  """
  @spec disable!(Autopilot.t(), atom()) :: Autopilot.t()
  def disable!(%Autopilot{} = autopilot, reason) do
    autopilot =
      if autopilot.enabled do
        autopilot
        |> Changeset.change(enabled: false, next_run_at: nil, disabled_reason: reason)
        |> Repo.update!()
      else
        autopilot
      end

    %{started: started, pending: pending} = open_records(autopilot.id)

    if pending, do: cancel!(pending, :autopilot_disabled)

    if started && started.run_id && started.config["mode"] == "run_only" &&
         Runs.cancel_pending(from(r in Run, where: r.id == ^started.run_id), :obsolete) > 0,
       do: cancel!(started, :autopilot_disabled)

    notify(autopilot)
  end

  @doc "Ends `record` as `cancelled` with `reason` (the count does not change)."
  @spec cancel!(Record.t(), atom()) :: Record.t()
  def cancel!(record, reason) do
    record =
      record
      |> Changeset.change(status: :cancelled, reason: to_string(reason), finished_at: Clock.now())
      |> Repo.update!()

    notify_record(record)
    record
  end

  @doc """
  Plans the next scheduled trigger after `after` (decision 5): sets
  `next_run_at` and inserts its `Fire` job; without a cron or when
  disabled, clears it.
  """
  @spec reschedule!(Autopilot.t(), DateTime.t()) :: Autopilot.t()
  def reschedule!(%Autopilot{enabled: true, cron: cron} = autopilot, base)
      when is_binary(cron) do
    at = Schedule.next_after(cron, autopilot.timezone, base)
    autopilot = autopilot |> Changeset.change(next_run_at: at) |> Repo.update!()
    if at, do: plan!(autopilot.id, at)
    notify(autopilot)
  end

  def reschedule!(%Autopilot{} = autopilot, _after) do
    if autopilot.next_run_at do
      autopilot |> Changeset.change(next_run_at: nil) |> Repo.update!() |> notify()
    else
      autopilot
    end
  end

  @doc "Inserts the `Fire` job of `(id, at)` (unique by its arguments)."
  @spec plan!(pos_integer(), DateTime.t()) :: :ok
  def plan!(id, %DateTime{} = at) do
    {:ok, _job} =
      %{autopilot_id: id, at: DateTime.to_iso8601(at)}
      |> FireJob.new(scheduled_at: at)
      |> Oban.insert()

    :ok
  end

  @doc "Announces a change of the autopilot after the commit."
  @spec notify(Autopilot.t()) :: Autopilot.t()
  def notify(%Autopilot{} = autopilot) do
    Events.after_commit_once(
      {:autopilot, autopilot.id},
      topic(autopilot.workspace_id),
      {:autopilot, autopilot.id}
    )

    autopilot
  end

  @doc "Announces a change of the record after the commit."
  @spec notify_record(Record.t()) :: Record.t()
  def notify_record(%Record{} = record) do
    Events.after_commit_once(
      {:autopilot_run, record.id},
      topic(record.workspace_id),
      {:autopilot_run, record.autopilot_id, record.id}
    )

    record
  end

  @doc "`text` cut to 4 KB on a UTF-8 boundary."
  @spec truncate(String.t() | nil) :: String.t() | nil
  def truncate(nil), do: nil

  def truncate(text) when is_binary(text) do
    {text, _} = Content.truncate_utf8(text, 4096)
    text
  end
end

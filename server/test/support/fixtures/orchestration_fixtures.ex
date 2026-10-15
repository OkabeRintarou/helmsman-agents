defmodule Helmsman.OrchestrationFixtures do
  @moduledoc """
  Test helpers for `improve-squad-leader-orchestration`: the squads
  workspace (`Helmsman.SquadsFixtures.squads_fixture/1`) with an epic led
  by `web-team` and its steps created by the leader as the squad
  (`orchestration_fixture/1`), and `leader_run/3`, a running run of an
  agent on a task with the capabilities `Helmsman.Runs.capabilities/4`
  computes.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Repo, Runs, Tasks}
  alias Helmsman.Runs.Run

  @doc """
  `squads_fixture/1` plus the epic `epic` assigned to `web-team` by alice
  (`start: false`) and, created by `keel/lead`'s run as the squad on the
  epic, the steps `s1` (`keel/fe`), `s2` (`keel/review`), `s3`
  (unassigned), all `start: false`. `lead_scope` / `lead_run`: that run.
  No queued run is left.
  """
  def orchestration_fixture(opts \\ %{}) do
    ctx = squads_fixture(opts)
    epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic, title: "Emulator"})
    {:ok, epic} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team", start: false})
    {:ok, epic} = Tasks.transition(ctx.alice_scope, epic.ident, :in_progress) |> reload(epic)
    {lead_scope, lead_run} = leader_run(ctx, ctx.lead, epic)

    step = fn title, assignee ->
      attrs = %{title: title, epic: epic.ident, start: false}
      attrs = if assignee, do: Map.put(attrs, :assignee, assignee), else: attrs
      {:ok, task} = Tasks.create(lead_scope, ctx.project.key, attrs)
      task
    end

    s1 = step.("Core", "keel/fe")
    s2 = step.("PPU", "keel/review")
    s3 = step.("Desktop", nil)
    drop_queued()

    Map.merge(ctx, %{
      epic: epic,
      s1: s1,
      s2: s2,
      s3: s3,
      lead_scope: lead_scope,
      lead_run: lead_run
    })
  end

  defp reload({:ok, _}, task), do: {:ok, Repo.reload!(task)}
  defp reload(other, _task), do: other

  @doc """
  A running run of `agent` on `task` (as `web-team` unless `squad: false`),
  its capabilities computed as when it is queued; returns `{scope, run}`.
  """
  def leader_run(ctx, %Actor{} = agent, task, opts \\ []) do
    squad_id = if Keyword.get(opts, :squad, true), do: ctx.squad.id
    task = Repo.reload!(task)
    caps = Runs.capabilities(profile(agent), task, [], squad_id)

    run =
      run_fixture(agent, %{
        task_id: task.id,
        status: :running,
        squad_id: squad_id,
        capabilities: caps,
        root_initiator_user_id: ctx.alice.id,
        causal_agent_ids: [agent.id]
      })

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end

  @doc "Removes the queued and deferred runs (assignment runs the tests do not look at)."
  def drop_queued do
    Repo.delete_all(from(r in Run, where: r.status in [:queued, :deferred]))
    :ok
  end
end

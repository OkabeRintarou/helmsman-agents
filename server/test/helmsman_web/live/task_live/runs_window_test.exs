defmodule HelmsmanWeb.TaskLive.RunsWindowTest do
  @moduledoc """
  Spec web-runs 排队运行很多 (design D8, D8a) on real runs: a task with 51 pending runs
  (one per agent, the pending runs of a task being unique per agent and lane).
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.Tasks

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "很多排队"})
    runtime_id = profile(ctx.agent).runtime_id

    agents =
      [ctx.agent] ++
        for n <- 2..51 do
          managed_agent_fixture(ctx.alice_scope, %{name: "agent-#{n}", runtime_id: runtime_id})
          agent_actor(ctx.workspace, "agent-#{n}")
        end

    runs = for agent <- agents, do: run_fixture(agent, %{task_id: task.id})

    Map.merge(ctx, %{
      conn: conn,
      task: task,
      runs: runs,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  test "51 pending runs all show, on mount and after a refresh", ctx do
    {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)

    for run <- ctx.runs, do: assert(has_element?(view, "#run-card-#{run.id}"))

    # keel/dev's run is claimed (the daemon takes one at a time): 50 pending + 1 active,
    # still complete after the reload.
    [first | rest] = ctx.runs
    set_run!(first.id, priority: 3)
    daemon = daemon_of(ctx.agent)
    Helmsman.Repo.update!(Ecto.Changeset.change(daemon, max_concurrency: 1))
    assert first.id in claim!(ctx.agent)

    eventually(fn ->
      has_element?(view, ~s(#run-card-#{first.id} [data-run-status="claimed"]))
    end)

    for run <- rest,
        do: assert(has_element?(view, ~s(#run-card-#{run.id} [data-run-status="queued"])))
  end
end

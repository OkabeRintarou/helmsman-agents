defmodule HelmsmanWeb.TaskLive.RunsWindowTest do
  @moduledoc """
  Spec web-runs 排队运行很多 (design D8, D8a) against the read functions of
  add-run-read-models (R9, R10), stood in for by `StubRuns` until that change is merged.
  Changes the application environment, so not async.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures

  alias Helmsman.Tasks

  defmodule StubRuns do
    @moduledoc false
    # R9 for a task returns every pending run (add-run-read-models decision 9).
    def list_open(_scope, {:task, _ident}, _opts) do
      pending = :persistent_term.get({__MODULE__, :pending})

      {:ok,
       %{
         active: :persistent_term.get({__MODULE__, :active}),
         pending: pending,
         pending_total: length(pending)
       }}
    end

    def list_finished(_scope, _target, _opts), do: {:ok, %{runs: [], total: 0}}
  end

  setup %{conn: conn} do
    previous = Application.get_env(:helmsman, HelmsmanWeb.RunData)
    Application.put_env(:helmsman, HelmsmanWeb.RunData, runs: StubRuns)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman, HelmsmanWeb.RunData, previous),
        else: Application.delete_env(:helmsman, HelmsmanWeb.RunData)
    end)

    ctx = dispatch_fixture()
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "很多排队"})
    Map.merge(ctx, %{conn: conn, task: task, path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"})
  end

  defp summary(id, status, agent) do
    %{
      id: id,
      task: nil,
      agent: agent,
      lane: "work",
      status: status,
      triggers: [],
      failure_reason: nil,
      priority: 2,
      inserted_at: DateTime.add(~U[2026-10-12 08:00:00.000000Z], id),
      updated_at: ~U[2026-10-12 08:00:00.000000Z]
    }
  end

  defp stub_runs(active, pending) do
    :persistent_term.put({StubRuns, :active}, active)
    :persistent_term.put({StubRuns, :pending}, pending)
  end

  test "51 pending runs all show, on mount and after a refresh", ctx do
    stub_runs([], Enum.map(1..51, &summary(&1, "queued", "agent-#{&1}")))
    {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)

    for id <- 1..51, do: assert(has_element?(view, "#run-card-#{id}"))

    # One starts: 50 pending + 1 active, still complete.
    stub_runs(
      [summary(1, "running", "agent-1")],
      Enum.map(2..51, &summary(&1, "queued", "agent-#{&1}"))
    )

    send(view.pid, :reload_runs)

    assert has_element?(view, ~s(#run-card-1 [data-run-status="running"]))

    for id <- 2..51,
        do: assert(has_element?(view, ~s(#run-card-#{id} [data-run-status="queued"])))
  end
end

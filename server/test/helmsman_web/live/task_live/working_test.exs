defmodule HelmsmanWeb.TaskLive.WorkingTest do
  @moduledoc """
  Spec web-runs 正在处理标记 and 运行进行中时的验收 on real runs (tasks 4.5, 4.6; design
  D8, D15): the task page's header marker and 验收 lock, and the task list's icon.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Tasks
  alias HelmsmanWeb.TaskLive.TransitionErrors

  setup %{conn: conn} do
    ctx = dispatch_fixture()

    {:ok, task} =
      Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录", labels: ["bug"]})

    {:ok, other} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "只排队"})
    slug = ctx.workspace.slug

    Map.merge(ctx, %{
      conn: conn,
      task: task,
      other: other,
      path: "/w/#{slug}/t/#{task.ident}",
      list: "/w/#{slug}/p/#{ctx.project.key}"
    })
  end

  defp open(ctx, path), do: live(log_in_user(ctx.conn, ctx.alice), path)

  defp label!(ctx, task, labels) do
    {:ok, current} = Tasks.get(ctx.alice_scope, task.ident)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{labels: labels}, current.lock_version)
  end

  defp second_agent(ctx) do
    runtime_id = profile(ctx.agent).runtime_id
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review", runtime_id: runtime_id})
    agent_actor(ctx.workspace, "keel/review")
  end

  describe "the header marker" do
    test "keel/dev 正在处理 opens the run's log; 等 2 个 with two agents", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id})
      {:ok, view, _html} = open(ctx, ctx.path)

      assert has_element?(view, "#task-working", "keel/dev 正在处理")
      view |> element("#task-working") |> render_click()
      assert_patch(view, "#{ctx.path}?run=#{run.id}")

      running_run!(second_agent(ctx), %{task_id: ctx.task.id})
      {:ok, view, _html} = open(ctx, ctx.path)
      assert has_element?(view, "#task-working", "keel/dev 等 2 个正在处理")
      assert has_element?(view, "#task-working-tip", "keel/dev、keel/review")
    end

    test "only a queued run: no marker; it appears and goes with the run", ctx do
      run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
      {:ok, view, _html} = open(ctx, ctx.path)
      refute has_element?(view, "#task-working")

      [_] = claim!(ctx.agent)
      eventually(fn -> has_element?(view, "#task-working", "keel/dev 正在处理") end)

      start!(ctx.agent, run.id)
      finish!(ctx.agent, run.id)
      eventually(fn -> not has_element?(view, "#task-working") end)
    end
  end

  describe "the task list" do
    test "a running task has the icon, a queued one has not; live, same process", ctx do
      run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
      queued = run_fixture(second_agent(ctx), %{task_id: ctx.other.id})
      {:ok, view, _html} = open(ctx, ctx.list)
      pid = view.pid

      refute has_element?(view, "#task-#{ctx.task.ident} [data-working]")

      Helmsman.Repo.update!(Ecto.Changeset.change(daemon_of(ctx.agent), max_concurrency: 1))
      Helmsman.RunLifecycleFixtures.set_run!(queued.id, priority: 1)
      Helmsman.RunLifecycleFixtures.set_run!(run.id, priority: 3)
      assert claim!(ctx.agent) == [run.id]
      start!(ctx.agent, run.id)

      eventually(fn ->
        has_element?(
          view,
          ~s(#task-#{ctx.task.ident} [data-working][aria-label="keel/dev 正在处理"])
        )
      end)

      refute has_element?(view, "#task-#{ctx.other.ident} [data-working]")

      finish!(ctx.agent, run.id)
      eventually(fn -> not has_element?(view, "#task-#{ctx.task.ident} [data-working]") end)
      assert view.pid == pid
    end

    test "a task entering the list with a run in progress has the icon at once (code-review-4)",
         ctx do
      {:ok, view, _html} = open(ctx, ctx.list <> "?label=bug")
      refute has_element?(view, "#task-#{ctx.other.ident}")

      run = running_run!(ctx.agent, %{task_id: ctx.other.id})
      label!(ctx, ctx.other, ["bug"])

      eventually(fn -> has_element?(view, "#task-#{ctx.other.ident}") end)
      assert has_element?(view, "#task-#{ctx.other.ident} [data-working]")

      # It leaves, its run ends outside the list, it comes back: no stale icon.
      label!(ctx, ctx.other, [])
      eventually(fn -> not has_element?(view, "#task-#{ctx.other.ident}") end)
      finish!(ctx.agent, run.id)
      label!(ctx, ctx.other, ["bug"])

      eventually(fn -> has_element?(view, "#task-#{ctx.other.ident}") end)
      refute has_element?(view, "#task-#{ctx.other.ident} [data-working]")
    end

    test "a run of a task that is not loaded is ignored", ctx do
      {:ok, view, _html} = open(ctx, ctx.list <> "?label=bug")
      refute has_element?(view, "#task-#{ctx.other.ident}")

      send(view.pid, {:run_updated, %{task: ctx.other.ident, agent: "keel/dev"}})
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.working_pending == MapSet.new()
      refute Map.has_key?(state.socket.assigns[:throttle_timers] || %{}, :reload_working)
    end
  end

  describe "验收 while a run is active" do
    setup ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id})
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :done)
      %{run: run}
    end

    test "disabled with the reason; usable once the run ends", ctx do
      {:ok, view, _html} = open(ctx, ctx.path)

      assert has_element?(view, ~s(#transition-verified[aria-disabled="true"]))
      assert has_element?(view, "#transition-verified-reason", "keel/dev 正在运行，等它结束后再验收")

      finish!(ctx.agent, ctx.run.id)
      eventually(fn -> not has_element?(view, ~s(#transition-verified[aria-disabled])) end)
    end

    test "a run starting while the panel is open: the reason on top, input kept", ctx do
      finish!(ctx.agent, ctx.run.id)
      {:ok, view, _html} = open(ctx, ctx.path)

      view |> element("#transition-verified") |> render_click()
      assert open?(view, "transition-panel")

      running_run!(ctx.agent, %{task_id: ctx.task.id})

      render_submit(view, "submit_transition", %{
        transition: %{commits: "", result: "none", comment: "看起来没问题"}
      })

      assert in_portal?(
               view,
               "transition-panel",
               "#transition-panel-error",
               "keel/dev 正在运行，等它结束后再验收"
             )

      assert portal_text(view, "transition-panel", "#transition-comment") =~ "看起来没问题"
      assert Tasks.get(ctx.alice_scope, ctx.task.ident) |> elem(1) |> Map.get(:status) == :done
    end
  end

  test "TransitionErrors explains run_active" do
    assert TransitionErrors.message({:run_active, %{id: 1, agent: "keel/review"}}, "验收") ==
             {:top, "keel/review 正在运行，等它结束后再验收"}
  end
end

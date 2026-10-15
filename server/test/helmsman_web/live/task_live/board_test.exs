defmodule HelmsmanWeb.TaskLive.BoardTest do
  use HelmsmanWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.PortalHelpers
  alias Helmsman.{Tasks, ViewPrefs}
  alias HelmsmanWeb.TaskLive.Board

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)

    Map.merge(ctx, %{
      conn: log_in_user(conn, ctx.alice),
      viewer: viewer,
      base: "/w/#{ctx.workspace.slug}/p/#{ctx.project.key}"
    })
  end

  defp create(ctx, attrs \\ %{}), do: task_fixture(ctx.alice_scope, ctx.project.key, attrs)
  defp open(ctx, query \\ ""), do: live(ctx.conn, ctx.base <> "?view=board" <> query)
  defp card(task, status), do: "#board-#{status}-#{task.ident}"

  test "default columns, empty targets, narrow anchors and hidden restore", ctx do
    {:ok, view, _} = open(ctx)

    for status <- ~w(new in_progress done verified),
        do: assert(has_element?(view, "#board-column-#{status}"))

    refute has_element?(view, "#board-column-rejected")
    assert has_element?(view, "#board-hidden-trigger", "已隐藏 2 列")
    assert has_element?(view, "#task-board.snap-x.snap-mandatory.overflow-x-auto")
    assert has_element?(view, ~s(a[href="#board-column-done"]))
    view |> element("#board-show-rejected") |> render_click()
    assert has_element?(view, "#board-column-rejected")
    view |> element("#board-hide-verified-popover [phx-click]") |> render_click()
    refute has_element?(view, "#board-column-verified")
    assert {:ok, %{hidden_columns: ["verified", "cancelled"]}} = ViewPrefs.get(ctx.alice_scope)
  end

  test "status filter overrides hidden and fixed order; one column cannot hide", ctx do
    {:ok, view, _} = open(ctx, "&status=cancelled,new")
    assert has_element?(view, "#board-column-new")
    assert has_element?(view, "#board-column-cancelled")
    refute has_element?(view, "#board-hidden-trigger")
    refute has_element?(view, "#board-hide-new-trigger")

    ViewPrefs.put(ctx.alice_scope, %{
      hidden_columns: ~w(in_progress done verified rejected cancelled)
    })

    {:ok, one, _} = open(ctx)
    refute has_element?(one, "#board-hide-new-trigger")
  end

  test "column paging and filtered counts; card title labels question epic run summaries", ctx do
    epic = create(ctx, %{kind: "epic", title: "Epic", labels: ["ui", "api", "db", "perf"]})
    create(ctx, %{epic: epic.ident})
    Helmsman.Feedback.add(ctx.alice_scope, epic.ident, %{kind: "question", content: "Question"})
    run_fixture(ctx.agent, %{task_id: epic.id, status: :deferred})
    for _ <- 1..29, do: create(ctx)
    {:ok, view, _} = open(ctx)

    assert Enum.count(
             view
             |> element("#board-cards-new")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("article")
           ) == 25

    assert has_element?(view, "[data-board-count=new]", "31")
    view |> element("#board-more-new") |> render_click()
    refute has_element?(view, "#board-more-new")
    assert has_element?(view, card(epic, "new") <> " .line-clamp-2", "Epic")
    assert has_element?(view, card(epic, "new") <> " [data-open-question]")
    assert has_element?(view, card(epic, "new") <> " [data-run-state=deferred]", "等前置任务")
    assert has_element?(view, card(epic, "new") <> " [data-epic-progress]")
    assert has_element?(view, card(epic, "new"), "+1")
  end

  test "direct movement, menu, invalid target and viewer permissions", ctx do
    task = create(ctx)
    {:ok, view, _} = open(ctx)
    refute has_element?(view, "#board-move-#{task.ident}-verified")
    assert has_element?(view, "#board-move-#{task.ident}-trigger[aria-label='移动 #{task.ident}']")
    render_hook(view, "move", %{id: task.ident, from: "new", to: "verified"})
    assert has_element?(view, card(task, "new"))
    view |> element("#board-move-#{task.ident}-in_progress") |> render_click()
    assert has_element?(view, card(task, "in_progress"))
    refute has_element?(view, card(task, "new"))
    assert has_element?(view, "#board-announcement", "#{task.ident} 已移到进行中")
    {:ok, viewer, _} = live(log_in_user(build_conn(), ctx.viewer.user), ctx.base <> "?view=board")
    refute has_element?(viewer, "[data-can-move=true]")
    refute has_element?(viewer, "#board-new-task")
    refute has_element?(viewer, "#board-move-#{task.ident}-trigger")
  end

  test "shared evidence and reason panels leave card until success; cancellation", ctx do
    task = create(ctx)
    Tasks.transition(ctx.alice_scope, task.ident, "in_progress", %{})
    Tasks.transition(ctx.alice_scope, task.ident, "done", %{})
    {:ok, view, _} = open(ctx)
    render_hook(view, "move", %{id: task.ident, from: "done", to: "in_progress"})
    assert in_portal?(view, "transition-panel", "#transition-panel-title", "打回 #{task.ident}")
    render_submit(view, "submit_transition", %{transition: %{comment: ""}, editor_session: "1"})
    assert in_portal?(view, "transition-panel", "#transition-editor", "请填写原因")
    assert has_element?(view, card(task, "done"))
    render_click(view, "close_transition")
    render_hook(view, "move", %{id: task.ident, from: "done", to: "verified"})
    assert in_portal?(view, "transition-panel", "#transition-panel-title", "验收 #{task.ident}")

    render_submit(view, "submit_transition", %{
      transition: %{result: "passed", command: "mix test"}
    })

    render(view)
    assert has_element?(view, card(task, "verified"))
    refute has_element?(view, card(task, "done"))
  end

  test "stale move restores actual card; realtime filter exit and counts", ctx do
    task = create(ctx, %{labels: ["ui"]})
    {:ok, view, _} = open(ctx, "&label=ui")
    {:ok, task} = Tasks.update(ctx.alice_scope, task.ident, %{labels: []})
    send(view.pid, {:task_updated, Tasks.summary(task)})
    refute has_element?(view, card(task, "new"))
    send(view.pid, :board_counts)
    assert has_element?(view, "[data-board-count=new]", "0")
    {:ok, unfiltered, _} = open(ctx)
    Tasks.transition(ctx.alice_scope, task.ident, "cancelled", %{comment: "cancel"})
    render_hook(unfiltered, "move", %{id: task.ident, from: "new", to: "in_progress"})
    assert render(unfiltered) =~ "任务状态已变为已撤销，无法开始"
    refute has_element?(unfiltered, card(task, "new"))
  end

  test "blocked start refused; hidden target announces; run changes only affected card", ctx do
    task = create(ctx)
    blocker = create(ctx)
    assert {:ok, _} = Helmsman.Links.add(ctx.alice_scope, task.ident, blocker.ident, "depends_on")
    {:ok, view, _} = open(ctx)
    render_hook(view, "move", %{id: task.ident, from: "new", to: "in_progress"})
    assert render(view) =~ "阻塞"
    assert has_element?(view, card(task, "new"))
    refute has_element?(view, "#board-move-#{task.ident}-in_progress")
    render_hook(view, "move", %{id: blocker.ident, from: "new", to: "cancelled"})

    render_submit(view, "submit_transition", %{
      transition: %{comment: "cancel"},
      editor_session: "1"
    })

    render(view)
    assert has_element?(view, "#board-announcement", "（该列已隐藏）")
    run_fixture(ctx.agent, %{task_id: task.id, status: :queued})
    unchanged = view |> element(card(task, "new")) |> render()
    send(view.pid, {:run_updated, %{task: task.ident}})
    send(view.pid, :board_runs)
    assert has_element?(view, card(task, "new") <> " [data-run-state=queued]", "排队中")
    assert unchanged != view |> element(card(task, "new")) |> render()
  end

  test "second process creates moves and search reloads only after throttle", ctx do
    {:ok, view, _} = open(ctx, "&q=needle")
    task = Task.async(fn -> create(ctx, %{title: "needle"}) end) |> Task.await()
    refute has_element?(view, card(task, "new"))
    send(view.pid, :board_search)
    assert has_element?(view, card(task, "new"))

    Task.async(fn -> Tasks.transition(ctx.alice_scope, task.ident, "in_progress", %{}) end)
    |> Task.await()

    send(view.pid, :board_search)
    assert has_element?(view, card(task, "in_progress"))
    refute has_element?(view, card(task, "new"))
  end

  test "running, queued, deferred and failed cards have distinct messages", ctx do
    tasks =
      for status <- [:running, :queued, :deferred, :failed] do
        task = create(ctx)

        run_fixture(ctx.agent, %{
          task_id: task.id,
          status: status,
          claimed_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

        {task, status}
      end

    {:ok, view, _} = open(ctx)

    for {task, status} <- tasks,
        do: assert(has_element?(view, card(task, "new") <> " [data-run-state=#{status}]"))

    assert render(view) =~ "keel/dev 正在处理"
    assert render(view) =~ "排队中"
    assert render(view) =~ "等前置任务"
    assert render(view) =~ "上次运行失败"
  end

  test "all six columns stay in order; filters count only matching cards", ctx do
    ViewPrefs.put(ctx.alice_scope, %{hidden_columns: []})
    task = create(ctx, %{labels: ["ui"]})
    create(ctx, %{labels: ["api"]})
    {:ok, view, _} = open(ctx, "&label=ui")

    columns =
      view
      |> element("#task-board")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-board-column]")
      |> LazyHTML.attribute("data-board-column")

    assert columns == ~w(new in_progress done verified rejected cancelled)
    assert has_element?(view, card(task, "new"))
    assert has_element?(view, "[data-board-count=new]", "1")
    assert has_element?(view, "#board-heading-done", "已完成")
  end

  test "empty loaded window refills from the column cursor", ctx do
    for _ <- 1..26, do: create(ctx, %{labels: ["ui"]})
    {:ok, view, _} = open(ctx, "&label=ui")

    loaded =
      view
      |> element("#board-cards-new")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("article")
      |> LazyHTML.attribute("data-task-id")

    Task.async(fn -> Enum.each(loaded, &Tasks.update(ctx.alice_scope, &1, %{labels: []})) end)
    |> Task.await(10_000)

    assert has_element?(view, "#board-cards-new article")
    refute has_element?(view, "#board-more-new")
    send(view.pid, :board_counts)
    assert has_element?(view, "[data-board-count=new]", "1")
  end

  test "run refresh sends just the changed card to its stream", ctx do
    one = create(ctx)
    two = create(ctx)
    run_fixture(ctx.agent, %{task_id: one.id, status: :queued})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: ctx.alice_scope},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    socket =
      socket
      |> Board.init()
      |> Phoenix.Component.assign(
        board_rows: Map.new([one, two], fn t -> {t.ident, Tasks.summary(t)} end),
        board_pending: MapSet.new([one.ident, two.ident])
      )

    refreshed = Board.refresh_runs(socket)

    assert Enum.map(refreshed.assigns.streams.board_new.inserts, fn {_dom, _at, row, _limit,
                                                                     _update} ->
             row.id
           end) == [one.ident]
  end

  test "editing within a column moves it to the top; duplicate summaries preserve nodes", ctx do
    one = create(ctx)
    create(ctx)
    {:ok, view, _} = open(ctx)
    {:ok, fresh} = Tasks.update(ctx.alice_scope, one.ident, %{title: "updated"})
    send(view.pid, {:task_updated, Tasks.summary(fresh)})

    assert has_element?(
             view,
             "#board-cards-new article:first-of-type[data-task-id='#{one.ident}']"
           )

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_scope: ctx.alice_scope,
        filters: %{},
        board_columns: ["new"]
      },
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    socket =
      socket
      |> Board.init()
      |> Phoenix.Component.assign(
        filters: %{},
        board_columns: ["new"],
        board_rows: %{one.ident => Tasks.summary(fresh)}
      )

    updated = Board.summary(socket, Tasks.summary(fresh))
    assert updated.assigns.streams.board_new.deletes == []
    cleared = Board.clear(updated)
    assert cleared.assigns.throttle_timers == %{}
  end
end

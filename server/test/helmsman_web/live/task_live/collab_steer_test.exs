defmodule HelmsmanWeb.TaskLive.CollabSteerTest do
  # add-collaboration-ui 5.1, 5.2: web-collaboration「插话勾选框」and the steering
  # line of「Feedback 的触发结果」.
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, dctx: 1]
  import Helmsman.RunsFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Feedback, Repo, Runs}
  alias Helmsman.Runs.Run

  @panel "feedback-panel"

  defp setup_ctx(conn, agent_attrs \\ %{}) do
    ctx = dispatch_fixture(agent_attrs)
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      bob_scope: bob_scope,
      task: task,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, user) do
    {:ok, view, _} = live(log_in_user(ctx.conn, user), ctx.path)
    view
  end

  defp open_add(view), do: view |> element("#feedback-add") |> render_click()
  defp session(view), do: portal_attr(view, @panel, "input[name=editor_session]", "value")

  defp submit(view, params),
    do: render_submit(view, "submit_feedback", %{feedback: params, editor_session: session(view)})

  defp checkbox(view), do: view |> portal(@panel) |> LazyHTML.query("#feedback-steer")
  defp checked?(view), do: checkbox(view) |> LazyHTML.attribute("checked") != []
  defp disabled?(view), do: checkbox(view) |> LazyHTML.attribute("disabled") != []
  defp help(view), do: portal_text(view, @panel, "#feedback-steer-help")

  defp entry(ctx) do
    {:ok, [entry | _]} = Feedback.list(ctx.alice_scope, ctx.task.ident)
    entry
  end

  test "插话送达", %{conn: conn} do
    ctx = setup_ctx(conn, %{provider: "codex"})
    run = running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.alice)
    open_add(view)

    assert in_portal?(view, @panel, "#feedback-steer-option", "同时发给正在运行的 keel/dev（运行 ##{run.id}）")
    assert checked?(view)
    refute disabled?(view)
    assert help(view) =~ "会立即送进这次运行"

    submit(view, %{kind: "comment", content: "换用方案 B", steer: "true"})
    refute open?(view, @panel)
    assert %{steer: %{run_id: run_id}} = entry(ctx)
    assert run_id == run.id

    assert has_element?(
             view,
             "#feedback-1-steer[data-steer=sent]",
             "已发给运行 ##{run.id}，等 keel/dev 接收"
           )

    {:ok, raw} = Feedback.get(ctx.alice_scope, "#{ctx.task.ident}#1")
    :ok = Runs.steer_ack(dctx(ctx.agent), run.id, raw.id)

    assert has_element?(view, "#feedback-1-steer[data-steer=acked]", "已送达运行 ##{run.id}（keel/dev）")
  end

  test "不支持实时接收", %{conn: conn} do
    ctx = setup_ctx(conn, %{provider: "copilot"})
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.alice)
    open_add(view)
    assert checked?(view)
    assert help(view) =~ "keel/dev 的 CLI 不能在运行中接收消息；勾选后会在这次运行结束后接着处理"
  end

  test "无权插话", %{conn: conn} do
    ctx = setup_ctx(conn)
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.bob)
    open_add(view)

    assert disabled?(view)
    refute checked?(view)
    assert help(view) =~ "你无权触发 keel/dev，不能插话"

    submit(view, %{kind: "comment", content: "看看", steer: "true"})
    assert %{steer: nil, dispatch: []} = entry(ctx)
  end

  test "不勾选", %{conn: conn} do
    ctx = setup_ctx(conn)
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.alice)
    open_add(view)
    submit(view, %{kind: "comment", content: "只是记录", steer: "false"})

    assert %{steer: nil, dispatch: []} = entry(ctx)
    refute has_element?(view, "#feedback-1-steer")
  end

  test "运行在面板打开期间结束", %{conn: conn} do
    ctx = setup_ctx(conn)
    run = running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.alice)
    open_add(view)

    render_change(view, "feedback_change", %{
      feedback: %{content: "草稿"},
      editor_session: session(view)
    })

    assert checked?(view)

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: :succeeded])
    send(view.pid, :reload_runs)

    refute in_portal?(view, @panel, "#feedback-steer-option")
    assert open?(view, @panel)
    assert :sys.get_state(view.pid).socket.assigns.feedback_panel.content == "草稿"
  end

  test "no running run, revisions and reasons have no checkbox", %{conn: conn} do
    ctx = setup_ctx(conn)
    view = open(ctx, ctx.alice)
    open_add(view)
    refute in_portal?(view, @panel, "#feedback-steer-option")
    render_click(view, "close_feedback", %{})

    {:ok, _} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "原文"})
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    view = open(ctx, ctx.alice)
    render_click(view, "open_feedback", %{mode: "revise", target: "#{ctx.task.ident}#1"})
    assert open?(view, @panel)
    refute in_portal?(view, @panel, "#feedback-steer-option")
  end

  test "插话没有排上队", %{conn: conn} do
    ctx = setup_ctx(conn)
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    for _ <- 1..19, do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :cancelled})
    view = open(ctx, ctx.alice)
    open_add(view)
    submit(view, %{kind: "comment", content: "换方案", steer: "true"})

    assert has_element?(
             view,
             "#feedback-1-steer[data-steer=skipped]",
             "没有插话 keel/dev：这个任务一小时内的运行次数已达上限"
           )
  end
end

defmodule HelmsmanWeb.TaskLive.CollabEpicTest do
  # add-collaboration-ui 2.3, 4.1–4.4: web-collaboration「建 Epic 与挂步骤」
  # 「Epic 的进度与步骤」「步骤所属的 Epic」.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Tasks

  setup %{conn: conn} do
    ctx = links_fixture()
    Map.merge(ctx, %{conn: conn, slug: ctx.workspace.slug})
  end

  defp open(ctx, path), do: live(log_in_user(ctx.conn, ctx.alice.user), "/w/#{ctx.slug}#{path}")
  defp epic!(ctx, key), do: task_fixture(ctx.owner, key, %{kind: "epic", title: "Epic #{key}"})
  defp step!(ctx, key, epic), do: task_fixture(ctx.owner, key, %{epic: epic.ident})

  defp fetch!(ctx, ident) do
    {:ok, task} = Tasks.get(ctx.owner, ident)
    task
  end

  defp new_task(view, :render_change, params),
    do: view |> with_target("#new-task-panel") |> render_change("change", %{task: params})

  defp new_task(view, :render_submit, params),
    do: view |> with_target("#new-task-panel") |> render_submit("submit", %{task: params})

  defp pick(view, panel, ident, ctx) do
    id = portal_attr(view, panel, "[data-task-picker]", "id")
    send(view.pid, {:task_picked, id, Tasks.summary(fetch!(ctx, ident))})
    render(view)
  end

  describe "建 Epic 与挂步骤" do
    test "建 Epic", ctx do
      {:ok, view, _} = open(ctx, "/p/BOS?panel=new")
      new_task(view, :render_change, %{project: "BOS", kind: "epic", title: "目标"})
      refute in_portal?(view, "new-task-dialog", "#new-task-epic")

      new_task(view, :render_submit, %{project: "BOS", kind: "epic", title: "目标"})
      {path, _flash} = assert_redirect(view)
      assert path == "/w/#{ctx.slug}/t/BOS-1"

      {:ok, page, _} = open(ctx, "/t/BOS-1")
      assert has_element?(page, "#task-kind [data-kind=epic]")
      assert has_element?(page, "#task-epic-empty", "还没有步骤")
      refute has_element?(page, "#task-epic-field")
    end

    test "从 Epic 添加步骤 (another project)", ctx do
      epic = epic!(ctx, "BOS")
      {:ok, page, _} = open(ctx, "/t/#{epic.ident}")
      assert page |> element("#epic-add-step") |> render() =~ "panel=new"

      {:ok, view, _} = open(ctx, "/t/#{epic.ident}?panel=new&epic=#{epic.ident}")

      assert portal_attr(view, "new-task-dialog", "#new-task-epic option[selected]", "value") ==
               epic.ident

      new_task(view, :render_change, %{project: "WEB", title: "步骤"})

      assert portal_attr(view, "new-task-dialog", "#new-task-epic option[selected]", "value") ==
               epic.ident

      new_task(view, :render_submit, %{
        project: "WEB",
        title: "步骤",
        kind: "task",
        epic: epic.ident
      })

      assert_redirect(view, "/w/#{ctx.slug}/t/WEB-1")
      assert fetch!(ctx, "WEB-1").epic_id == epic.id
    end

    test "the epics of the chosen project, and a field error", ctx do
      bos = epic!(ctx, "BOS")
      web = epic!(ctx, "WEB")
      {:ok, view, _} = open(ctx, "/p/BOS?panel=new")

      options =
        view
        |> portal("new-task-dialog")
        |> LazyHTML.query("#new-task-epic option")
        |> LazyHTML.attribute("value")

      assert options == ["", bos.ident]

      new_task(view, :render_change, %{project: "WEB"})

      options =
        view
        |> portal("new-task-dialog")
        |> LazyHTML.query("#new-task-epic option")
        |> LazyHTML.attribute("value")

      assert options == ["", web.ident]

      [plain] = tasks!(ctx.owner, "BOS", 1)

      new_task(view, :render_submit, %{
        project: "BOS",
        title: "x",
        kind: "task",
        epic: plain.ident
      })

      assert in_portal?(view, "new-task-dialog", "#new-task-dialog", "不是 Epic")
    end
  end

  describe "Epic 的进度与步骤" do
    test "进度", ctx do
      epic = epic!(ctx, "BOS")
      steps = for key <- ~w(BOS WEB BOS BOS), do: step!(ctx, key, epic)

      for {step, status} <- Enum.zip(steps, [:done, :verified, :cancelled, :in_progress]),
          do: set_status!(step, status)

      {:ok, view, _} = open(ctx, "/t/#{epic.ident}")
      assert has_element?(view, "#task-epic-count", "2/4")
      assert has_element?(view, ~s(#task-epic-progress[aria-valuenow="2"][aria-valuemax="4"]))

      for status <- ~w(done verified cancelled in_progress),
          do: assert(has_element?(view, ~s(#task-epic-counts [data-status="#{status}"]), "1"))

      refute has_element?(view, ~s(#task-epic-counts [data-status="new"]))

      ids =
        view
        |> element("#task-epic-steps")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li")
        |> LazyHTML.attribute("id")

      assert ids == Enum.map(steps, &"epic-step-#{&1.ident}")
    end

    test "挂上已有任务 and 移出", ctx do
      epic = epic!(ctx, "BOS")
      [loose] = tasks!(ctx.owner, "BOS", 1)
      {:ok, view, _} = open(ctx, "/t/#{epic.ident}")

      view |> element("#epic-attach") |> render_click()
      assert open?(view, "epic-panel")
      pick(view, "epic-panel", loose.ident, ctx)
      html = render_click(view, "collab_epic_submit", %{})
      assert html =~ "已挂上 #{loose.ident}"
      assert has_element?(view, "#epic-step-#{loose.ident}")
      assert has_element?(view, "#task-epic-count", "0/1")

      step = fetch!(ctx, loose.ident)
      html = render_click(view, "collab_detach", %{task: loose.ident, version: step.lock_version})
      assert html =~ "已移出 #{loose.ident}"
      refute has_element?(view, "#epic-step-#{loose.ident}")

      {:ok, page, _} = open(ctx, "/t/#{loose.ident}")
      assert has_element?(page, "#task-epic-field", "—")
    end

    test "挂上 a task changed meanwhile", ctx do
      epic = epic!(ctx, "BOS")
      [loose] = tasks!(ctx.owner, "BOS", 1)
      {:ok, view, _} = open(ctx, "/t/#{epic.ident}")
      view |> element("#epic-attach") |> render_click()
      pick(view, "epic-panel", loose.ident, ctx)
      {:ok, _} = Tasks.update(ctx.owner, loose.ident, %{title: "改了"})

      render_click(view, "collab_epic_submit", %{})
      assert portal_text(view, "epic-panel", "#epic-panel-error") =~ "#{loose.ident} 已被修改，请重试"
    end

    test "最后一步完成时实时更新", ctx do
      epic = epic!(ctx, "BOS")
      [a, b] = for _ <- 1..2, do: step!(ctx, "BOS", epic)
      {:ok, _} = Tasks.transition(ctx.owner, epic.ident, "in_progress")
      {:ok, _} = Tasks.transition(ctx.owner, a.ident, "in_progress")
      {:ok, _} = Tasks.transition(ctx.owner, a.ident, "done")
      {:ok, _} = Tasks.transition(ctx.owner, b.ident, "in_progress")
      assert fetch!(ctx, epic.ident).status == :in_progress

      {:ok, view, _} = open(ctx, "/t/#{epic.ident}")
      {:ok, list, _} = open(ctx, "/p/BOS")
      assert has_element?(list, ~s(#tasks [data-epic-progress][data-progress="1/2"]))

      {:ok, _} = Tasks.transition(ctx.keel, b.ident, "done")

      assert has_element?(view, "#task-epic-count", "2/2")
      assert has_element?(view, "#task-status [data-status=done]")
      assert render(view) =~ "all steps completed (auto)"
      assert has_element?(list, ~s(#tasks [data-epic-progress][data-progress="2/2"]))
    end
  end

  describe "步骤所属的 Epic" do
    test "改所属 Epic", ctx do
      epic = epic!(ctx, "BOS")
      other = epic!(ctx, "BOS")
      step = step!(ctx, "WEB", epic)
      {:ok, view, _} = open(ctx, "/t/#{step.ident}")
      assert has_element?(view, "#task-epic-field", epic.ident)
      assert has_element?(view, ~s(#task-epic-field-progress[data-progress="0/1"]))

      view |> element("#task-epic-edit") |> render_click()
      pick(view, "epic-panel", other.ident, ctx)
      render_click(view, "collab_epic_submit", %{})

      assert has_element?(view, "#task-epic-field", other.ident)
      assert has_element?(view, ~s(#task-epic-field-progress[data-progress="0/1"]))
      assert fetch!(ctx, step.ident).epic_id == other.id

      view |> element("#task-epic-edit") |> render_click()
      render_click(view, "collab_epic_clear", %{})
      assert has_element?(view, "#task-epic-field", "—")
    end

    test "a stale save reloads", ctx do
      epic = epic!(ctx, "BOS")
      [task] = tasks!(ctx.owner, "WEB", 1)
      {:ok, view, _} = open(ctx, "/t/#{task.ident}")
      view |> element("#task-epic-edit") |> render_click()
      {:ok, _} = Tasks.update(ctx.owner, task.ident, %{title: "改了"})
      pick(view, "epic-panel", epic.ident, ctx)

      assert render_click(view, "collab_epic_submit", %{}) =~ "此任务已被其他人修改"
      assert fetch!(ctx, task.ident).epic_id == nil
    end

    test "兄弟步骤完成", ctx do
      epic = epic!(ctx, "BOS")
      step = step!(ctx, "WEB", epic)
      sibling = step!(ctx, "BOS", epic)
      {:ok, view, _} = open(ctx, "/t/#{step.ident}")
      assert has_element?(view, ~s(#task-epic-field-progress[data-progress="0/2"]))

      {:ok, _} = Tasks.transition(ctx.owner, sibling.ident, "in_progress")
      {:ok, _} = Tasks.transition(ctx.owner, sibling.ident, "done")
      assert has_element?(view, ~s(#task-epic-field-progress[data-progress="1/2"]))
    end
  end
end

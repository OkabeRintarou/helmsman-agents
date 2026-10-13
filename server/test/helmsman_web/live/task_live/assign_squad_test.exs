defmodule HelmsmanWeb.TaskLive.AssignSquadTest do
  @moduledoc """
  Spec web-squads 指派给小队、提及小队 (add-squads-autopilots-ui D6), against
  `Helmsman.Squads`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Daemons.Runtime
  alias Helmsman.{Repo, Squads, Tasks}
  alias HelmsmanWeb.{CollabComponents, RunComponents, TaskComponents}
  alias HelmsmanWeb.TaskLive.Show

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {bob, _bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/qa", access: "owner_only"})

    {:ok, _} =
      Squads.create(ctx.alice_scope, %{
        name: "web-team",
        leader: "keel/dev",
        members: [%{name: "keel/qa", role_note: "测试"}]
      })

    {:ok, _} = Squads.create(ctx.alice_scope, %{name: "old-team", leader: "keel/dev"})
    {:ok, _} = Squads.disable(ctx.alice_scope, "old-team")
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      task: task,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, user), do: live(log_in_user(ctx.conn, user), ctx.path)

  defp choose(view, name),
    do: view |> element("#" <> Show.assignee_item_id(name)) |> render_click()

  defp dialog_buttons(view),
    do:
      view
      |> portal("assign-confirm")
      |> LazyHTML.query("button")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp dialog_text(view), do: view |> portal("assign-confirm") |> LazyHTML.text()

  test "分组：人、Agent、小队；停用的小队不出现", ctx do
    {:ok, view, _html} = open(ctx, ctx.alice)
    html = view |> element("#task-assignee") |> render()

    headings =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[role=presentation]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

    assert headings == ["人", "Agent", "小队"]
    [_, squads] = String.split(html, "小队", parts: 2)
    assert squads =~ "web-team"
    refute html =~ "old-team"
    assert has_element?(view, "#" <> Show.assignee_item_id("web-team") <> " .lucide-users")
  end

  test "指派给小队：能触发时的确认对话框", ctx do
    {:ok, view, _html} = open(ctx, ctx.alice)
    choose(view, "web-team")

    assert open?(view, "assign-confirm")
    assert dialog_text(view) =~ "把 #{ctx.task.ident} 指派给 web-team"
    assert dialog_text(view) =~ "web-team 的 leader keel/dev 会排队运行，由它决定谁来做"
    assert dialog_buttons(view) == ["取消", "暂不开始", "开始"]
  end

  test "指派给小队并开始（真实领域）", ctx do
    {:ok, view, _html} = open(ctx, ctx.alice)
    choose(view, "web-team")

    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)

    html =
      render_click(view, "confirm_assign", %{
        "agent" => "web-team",
        "version" => task.lock_version,
        "start" => "true"
      })

    assert html =~ "已派发给 web-team（leader keel/dev）"
    assert has_element?(view, "#task-assignee", "web-team")

    assert {:ok, [%{status: "queued", agent: "keel/dev", squad: %{name: "web-team"}}]} =
             Helmsman.Runs.list_for_task(ctx.alice_scope, ctx.task.ident)
  end

  test "被成员挡住：仍然指派不启动运行（真实领域）", ctx do
    {:ok, view, _html} = open(ctx, ctx.bob)
    choose(view, "web-team")
    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)

    render_click(view, "confirm_assign", %{
      "agent" => "web-team",
      "version" => task.lock_version,
      "start" => "false"
    })

    assert has_element?(view, "#task-assignee", "web-team")
    assert {:ok, []} = Helmsman.Runs.list_for_task(ctx.alice_scope, ctx.task.ident)
  end

  test "被成员挡住", ctx do
    {:ok, view, _html} = open(ctx, ctx.bob)

    assert has_element?(
             view,
             "#" <> Show.assignee_item_id("web-team") <> "[data-unavailable]",
             "你无权触发 keel/qa"
           )

    choose(view, "web-team")
    assert dialog_text(view) =~ "你无权触发 keel/qa。仍可指派，但不会启动运行"
    assert dialog_buttons(view) == ["取消", "仍然指派（不会启动运行）"]
  end

  test "leader 的运行时离线时附排队说明", ctx do
    Repo.update_all(Runtime, set: [status: "offline"])
    {:ok, view, _html} = open(ctx, ctx.alice)
    choose(view, "web-team")

    assert dialog_text(view) =~ "web-team 的 leader keel/dev 的运行时"
    assert dialog_text(view) =~ "当前离线"
  end

  test "新建任务面板：分组与说明", ctx do
    {:ok, view, _html} =
      live(
        log_in_user(ctx.conn, ctx.bob),
        "/w/#{ctx.workspace.slug}/p/#{ctx.project.key}?panel=new"
      )

    assert in_portal?(
             view,
             "new-task-dialog",
             ~s|#new-task-assignee optgroup[label="小队"] option[value="web-team"]|
           )

    view
    |> with_target("#new-task-panel")
    |> render_change("change", %{task: %{"assignee" => "web-team", "title" => "x"}})

    assert in_portal?(
             view,
             "new-task-dialog",
             "#new-task-start-note",
             "你无权触发 keel/qa，创建后不会启动运行"
           )
  end

  test "派发结果提示" do
    base = %{squad: "web-team", agent: "keel/lead"}

    assert RunComponents.dispatch_message(Map.put(base, :result, :queued)) ==
             {:info, "已派发给 web-team（leader keel/lead）"}

    assert RunComponents.dispatch_message(Map.put(base, :result, "merged")) ==
             {:info, "已并入 keel/lead 排队中的运行"}

    assert RunComponents.dispatch_message(
             Map.merge(base, %{result: :skipped, reason: :unauthorized, refused: ["keel/qa"]})
           ) == {:warning, "没有启动 web-team：你无权触发 keel/qa"}

    assert RunComponents.dispatch_message(
             Map.merge(base, %{result: "skipped", reason: "squad_disabled"})
           ) == {:warning, "没有启动 web-team：小队已停用"}

    assert RunComponents.dispatch_message(
             Map.merge(base, %{result: :skipped, reason: :not_started})
           ) == {:info, "已指派给 web-team，暂不开始"}

    assert RunComponents.dispatch_message(
             Map.merge(base, %{result: :skipped, reason: :no_runtime})
           ) ==
             {:warning, "没有启动 web-team：它没有绑定运行时"}
  end

  describe "提及小队" do
    test "@ 补全列出小队并标出「小队」", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, __MODULE__.EditorLive)

      view
      |> with_target("#squad-editor")
      |> render_hook("mention_query", %{"q" => "web", "session" => 1})

      assert has_element?(
               view,
               "#squad-editor-mention-0[data-name='web-team'] [data-squad]",
               "小队"
             )

      assert has_element?(view, "#squad-editor-mention-0 .lucide-users")
    end

    test "Feedback 的触发记录显示小队与 leader" do
      html =
        render_component(&CollabComponents.dispatch_line/1,
          dom_id: "fb-1",
          entry: %{
            dispatch: [
              %{
                trigger: "mention",
                agent: "keel/dev",
                squad: "web-team",
                result: "queued",
                reason: nil,
                run_id: nil
              }
            ]
          }
        )

      assert html =~ "web-team（keel/dev）"
    end
  end

  # code-review-1 P2-3: an assigned squad that was disabled keeps the 已停用 mark, on
  # the link (read-only) and in the menu trigger (no slug).
  test "已指派的小队停用后带停用标记", ctx do
    agents = HelmsmanWeb.TaskData.agent_info(ctx.alice_scope)
    assert agents["old-team"].state == :disabled

    for slug <- ["acme", nil] do
      html =
        render_component(&TaskComponents.actor_ref/1,
          actor: %{name: "old-team", kind: "squad"},
          agents: agents,
          slug: slug
        )

      assert html =~ "old-team（已停用）"
    end

    refute HelmsmanWeb.TaskData.assignable(ctx.alice_scope) |> Enum.any?(&(&1.name == "old-team"))
  end

  test "actor 标识中的小队链接到详情页" do
    html =
      render_component(&TaskComponents.actor_ref/1,
        actor: %{name: "web-team", kind: "squad"},
        slug: "acme"
      )

    assert html =~ ~s(href="/w/acme/squads/web-team")
  end

  defmodule EditorLive do
    use Phoenix.LiveView

    def render(assigns) do
      ~H"""
      <.live_component
        module={HelmsmanWeb.MarkdownEditor}
        id="squad-editor"
        session={1}
        scope={nil}
        name="c"
        value=""
        submit={:form}
        candidates={[%{name: "web-team", kind: "squad"}, %{name: "alice", kind: "human"}]}
      />
      """
    end
  end
end

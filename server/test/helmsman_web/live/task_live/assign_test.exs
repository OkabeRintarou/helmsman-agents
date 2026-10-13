defmodule HelmsmanWeb.TaskLive.AssignTest do
  @moduledoc "Spec web-runs 指派确认、派发结果提示; web-tasks 指派托管 Agent 需要确认 (design D11)."
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.RunsFixtures

  alias Helmsman.{Actors, Agents, Repo, Runtimes, Tasks}
  alias Helmsman.Daemons.Runtime
  alias HelmsmanWeb.TaskLive.Show

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})
    {:ok, agent} = Agents.get(ctx.alice_scope, "keel/dev")

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      bob_scope: bob_scope,
      task: task,
      runtime_id: agent.runtime.id,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, who \\ :alice),
    do: live(log_in_user(ctx.conn, if(who == :alice, do: ctx.alice, else: ctx.bob)), ctx.path)

  defp choose(view, name),
    do: view |> element("#" <> Show.assignee_item_id(name)) |> render_click()

  defp version(ctx), do: elem(Tasks.get(ctx.alice_scope, ctx.task.ident), 1).lock_version
  defp assignee(ctx), do: elem(Tasks.get(ctx.alice_scope, ctx.task.ident), 1).assignee
  defp runs(ctx), do: runs_of(ctx.task.id)

  defp confirm(view, ctx, start, version \\ nil),
    do:
      render_click(view, "confirm_assign", %{
        "agent" => "keel/dev",
        "version" => version || version(ctx),
        "start" => to_string(start)
      })

  # The `confirm_assign` push of a dialog button as the browser sends it: the JSON
  # value of its `phx-click` (booleans stay booleans).
  defp dialog_push(view, label) do
    button =
      view
      |> portal("assign-confirm")
      |> LazyHTML.query("button")
      |> Enum.find(&(String.trim(LazyHTML.text(&1)) == label))

    [js] = LazyHTML.attribute(button, "phx-click")

    js
    |> Jason.decode!()
    |> Enum.find_value(fn
      ["push", %{"event" => "confirm_assign", "value" => value}] -> value
      _ -> nil
    end)
  end

  defp dialog_buttons(view),
    do:
      view
      |> portal("assign-confirm")
      |> LazyHTML.query("button")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  test "指派并开始", ctx do
    {:ok, view, _html} = open(ctx)
    choose(view, "keel/dev")

    assert open?(view, "assign-confirm")

    assert in_portal?(
             view,
             "assign-confirm",
             "#assign-confirm-title",
             "把 #{ctx.task.ident} 指派给 keel/dev"
           )

    assert dialog_buttons(view) == ["取消", "暂不开始", "开始"]
    assert assignee(ctx) == nil

    html = confirm(view, ctx, true)
    assert html =~ "已派发给 keel/dev"
    assert has_element?(view, "#task-assignee", "keel/dev")

    assert {:ok, [%{status: "queued"}]} =
             Helmsman.Runs.list_for_task(ctx.alice_scope, ctx.task.ident)
  end

  test "暂不开始", ctx do
    {:ok, view, _html} = open(ctx)
    choose(view, "keel/dev")

    assert confirm(view, ctx, false) =~ "已指派给 keel/dev，暂不开始"
    assert assignee(ctx).name == "keel/dev"
    assert runs(ctx) == []
  end

  test "an offline runtime: the run will wait", ctx do
    Repo.update_all(from(r in Runtime, where: r.id == ^ctx.runtime_id), set: [status: "offline"])
    {:ok, view, _html} = open(ctx)

    assert has_element?(view, ~s(##{Show.assignee_item_id("keel/dev")}[data-runtime-offline]))
    choose(view, "keel/dev")
    assert in_portal?(view, "assign-confirm", "#assign-confirm-description", "当前离线，运行会排队")
    assert dialog_buttons(view) == ["取消", "暂不开始", "开始"]
  end

  test "无权触发: still selectable, never starts", ctx do
    {:ok, view, _html} = open(ctx, :bob)
    item = "#" <> Show.assignee_item_id("keel/dev")

    assert has_element?(view, "#{item}[data-unavailable]", "你无权触发 keel/dev")
    choose(view, "keel/dev")

    assert dialog_buttons(view) == ["取消", "仍然指派（不会启动运行）"]
    html = confirm(view, ctx, false)
    assert html =~ "keel/dev"
    assert assignee(ctx).name == "keel/dev"
    assert runs(ctx) == []
  end

  test "choosing a person needs no confirmation", ctx do
    name = Actors.get_human(ctx.workspace.id, ctx.bob.id).name
    {:ok, view, _html} = open(ctx)
    choose(view, name)

    refute open?(view, "assign-confirm")
    assert assignee(ctx).name == name
  end

  test "运行时被禁用 while the dialog is open", ctx do
    {:ok, view, _html} = open(ctx)
    choose(view, "keel/dev")
    {:ok, _} = Runtimes.disable(ctx.alice_scope, ctx.runtime_id)

    assert confirm(view, ctx, true) =~ "没有启动 keel/dev：运行时已禁用"
    assert assignee(ctx).name == "keel/dev"
    assert runs(ctx) == []
  end

  test "不可用期间恢复可用: the promise not to start holds", ctx do
    {:ok, _} = Runtimes.disable(ctx.alice_scope, ctx.runtime_id)
    {:ok, view, _html} = open(ctx)
    choose(view, "keel/dev")
    assert dialog_buttons(view) == ["取消", "仍然指派（不会启动运行）"]

    {:ok, _} = Runtimes.enable(ctx.alice_scope, ctx.runtime_id)
    assert confirm(view, ctx, false) =~ "已指派给 keel/dev，暂不开始"
    assert assignee(ctx).name == "keel/dev"
    assert runs(ctx) == []
  end

  test "unauthorized when opened, authorized when clicked: still no run", ctx do
    {:ok, view, _html} = open(ctx, :bob)
    choose(view, "keel/dev")
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: "workspace"})

    confirm(view, ctx, false)
    assert assignee(ctx).name == "keel/dev"
    assert runs(ctx) == []
  end

  test "a done task saves at once", ctx do
    {:ok, task} = Tasks.transition(ctx.alice_scope, ctx.task.ident, "in_progress", %{})
    {:ok, _} = Tasks.transition(ctx.alice_scope, task.id, "done", %{})
    {:ok, view, _html} = open(ctx)

    choose(view, "keel/dev")
    refute open?(view, "assign-confirm")
    assert assignee(ctx).name == "keel/dev"
  end

  test "a change while the dialog is open is a version conflict", ctx do
    {:ok, view, _html} = open(ctx)
    opened = version(ctx)
    choose(view, "keel/dev")
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{title: "别人改的"}, opened)

    assert confirm(view, ctx, true, opened) =~ "此任务已被其他人修改"
    assert assignee(ctx) == nil
    assert runs(ctx) == []
  end

  describe "the payload of the dialog's own buttons (M5 F1)" do
    test "开始 pushes a boolean `start: true` and starts", ctx do
      {:ok, view, _html} = open(ctx)
      choose(view, "keel/dev")

      value = dialog_push(view, "开始")
      assert value["start"] == true
      assert render_click(view, "confirm_assign", value) =~ "已派发给 keel/dev"
      refute render(view) =~ "暂不开始"
      assert assignee(ctx).name == "keel/dev"
      assert [%{status: :queued}] = runs(ctx)
    end

    test "暂不开始 pushes a boolean `start: false` and does not start", ctx do
      {:ok, view, _html} = open(ctx)
      choose(view, "keel/dev")

      value = dialog_push(view, "暂不开始")
      assert value["start"] == false
      assert render_click(view, "confirm_assign", value) =~ "已指派给 keel/dev，暂不开始"
      assert assignee(ctx).name == "keel/dev"
      assert runs(ctx) == []
    end

    test "string payloads (`phx-value-*`) behave the same", ctx do
      {:ok, view, _html} = open(ctx)
      choose(view, "keel/dev")
      assert confirm(view, ctx, "true") =~ "已派发给 keel/dev"
      assert [%{status: :queued}] = runs(ctx)
    end
  end
end

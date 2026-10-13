defmodule HelmsmanWeb.TaskLive.ActorModeTest do
  @moduledoc "Actor chips on the task pages tell managed from external agents (M5 F2)."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.ApiTokensFixtures

  alias Helmsman.{Feedback, Tasks}

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    agent_fixture(ctx.workspace, ctx.alice, "alice/session-x")
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})
    Map.merge(ctx, %{conn: conn, task: task})
  end

  defp assign!(ctx, name) do
    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)

    {:ok, _} =
      Tasks.update(
        ctx.alice_scope,
        ctx.task.ident,
        %{assignee: name, start: false},
        task.lock_version
      )
  end

  defp open(ctx, path \\ nil),
    do:
      live(
        log_in_user(ctx.conn, ctx.alice),
        path || "/w/#{ctx.workspace.slug}/t/#{ctx.task.ident}"
      )

  defp text(view, selector), do: view |> element(selector) |> render()

  test "a managed assignee is 托管 on the task page and in the list", ctx do
    assign!(ctx, "keel/dev")

    {:ok, view, _html} = open(ctx)
    assignee = text(view, "#task-assignee")
    assert assignee =~ "托管"
    refute assignee =~ "外接"

    {:ok, list, _html} = open(ctx, "/w/#{ctx.workspace.slug}/p/#{ctx.project.key}")
    row = text(list, "#task-#{ctx.task.ident}")
    assert row =~ "托管"
    refute row =~ "外接"
  end

  test "an external assignee stays 外接", ctx do
    assign!(ctx, "alice/session-x")
    {:ok, view, _html} = open(ctx)
    assert text(view, "#task-assignee") =~ "外接"
  end

  test "a managed agent's feedback is 托管", ctx do
    run =
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"],
        root_initiator_user_id: ctx.alice.id
      })

    {scope, _token} = run_scope_fixture(run)
    {:ok, _} = Feedback.add(scope, ctx.task.ident, %{kind: "comment", content: "进度"})

    {:ok, view, _html} = open(ctx)
    card = text(view, "#feedback-threads article")
    assert card =~ "keel/dev"
    assert card =~ "托管"
    refute card =~ "外接"
  end
end

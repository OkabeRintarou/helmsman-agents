defmodule HelmsmanWeb.TaskLive.SpecCardTest do
  @moduledoc """
  Spec web-specs 任务页的规格卡片 (add-spec-workflow-ui tasks 4.1) on the real domain.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.ProjectsFixtures
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.TaskSpecs

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    Map.put(ctx, :conn, conn)
  end

  defp open(ctx, user, path \\ nil), do: live(log_in_user(ctx.conn, user), path || ctx.task_path)

  test "有规格的任务", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2, change_id: "add-settings-page")
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"], %{})
    review(ctx, 2, "fail", [%{severity: "P1", body: "x"}], ctx.qa)

    {:ok, view, _html} = open(ctx, ctx.bob)
    assert has_element?(view, "#task-spec-status", "评审中")
    assert has_element?(view, "#task-spec-change-id", "add-settings-page")
    assert has_element?(view, "#task-spec-latest[data-valid=true]", "v2 ✓")
    assert has_element?(view, "#task-spec-pending", "keel/review")
    assert has_element?(view, "#task-spec-unresolved", "P1 1")
    assert has_element?(view, "#task-spec-mode", "需要人批准")
    assert has_element?(view, ~s(#task-spec-open[href="#{ctx.path}"]))
  end

  test "开始规格", ctx do
    {:ok, view, _html} = open(ctx, ctx.bob)
    assert has_element?(view, "#task-spec-none", "这个任务还没有规格")

    view |> element("#task-spec-start") |> render_click()
    assert has_element?(view, "#task-spec-status", "草稿")
    assert has_element?(view, "#task-spec-change-id", String.downcase(ctx.ident))
    assert has_element?(view, "#task-spec-latest", "还没有版本")
    refute has_element?(view, "#task-spec-start")
  end

  test "待批准", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 3)
    propose(ctx, 3)
    {:ok, view, _html} = open(ctx, ctx.alice)

    assert has_element?(view, "#task-spec-status", "待批准")
    assert has_element?(view, "#task-spec-proposal", "keel/lead 提议 v3")
    assert has_element?(view, "#task-spec-proposal", "R1 settled")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#task-spec-approve") |> render_click()

    assert to == ctx.path <> "?panel=finalize"
    assert {:ok, %{status: :pending_approval}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
  end

  test "viewer", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 1)
    propose(ctx, 1)
    {:ok, view, _html} = open(ctx, ctx.vic)

    assert has_element?(view, "#task-spec-status")
    refute has_element?(view, "#task-spec-approve")
    refute has_element?(view, "#task-spec-reject")

    other = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, plain, _html} = open(ctx, ctx.vic, "/w/#{ctx.slug}/t/#{other.ident}")
    assert has_element?(plain, "#task-spec-none")
    refute has_element?(plain, "#task-spec-start")
  end

  test "the epic's spec", ctx do
    epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic"})
    spec_fixture(ctx.alice_scope, epic.ident, versions: 2)
    {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, epic.ident, %{version: 2, wake: false})
    step = task_fixture(ctx.alice_scope, ctx.project.key, epic: epic.ident)

    {:ok, view, _html} = open(ctx, ctx.bob, "/w/#{ctx.slug}/t/#{step.ident}")
    assert has_element?(view, "#task-spec-epic", "Epic #{epic.ident} 的规格：已定稿 v2")
    assert has_element?(view, ~s(#task-spec-epic[href="/w/#{ctx.slug}/t/#{epic.ident}/spec"]))
  end
end

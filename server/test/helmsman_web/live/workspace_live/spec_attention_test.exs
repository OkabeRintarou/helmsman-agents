defmodule HelmsmanWeb.WorkspaceLive.SpecAttentionTest do
  @moduledoc """
  Spec web-specs 首页的待处理规格 (add-spec-workflow-ui D16, tasks 4.2).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.ProjectsFixtures
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.TaskSpecs

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 1)
    spec_fixture(ctx.alice_scope, other.ident, versions: 2)
    Map.merge(ctx, %{conn: conn, other: other.ident, home: "/w/#{ctx.slug}"})
  end

  test "待处理", ctx do
    propose(ctx, 1)
    bob = ctx.bob_scope.actor.name
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.other, [bob], %{})

    {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.bob), ctx.home)
    assert has_element?(view, "#spec-attention-approve-#{ctx.ident}", "keel/lead")

    assert has_element?(
             view,
             ~s(#spec-attention-approve-#{ctx.ident}[href="/w/#{ctx.slug}/t/#{ctx.ident}/spec?panel=finalize"])
           )

    assert has_element?(view, "#spec-attention-review-#{ctx.other}", "v2")

    assert has_element?(
             view,
             ~s(#spec-attention-review-#{ctx.other}[href="/w/#{ctx.slug}/t/#{ctx.other}/spec?panel=review"])
           )
  end

  test "viewer", ctx do
    propose(ctx, 1)
    {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.vic), ctx.home)
    refute has_element?(view, "#spec-attention")
  end

  test "实时", ctx do
    propose(ctx, 1)
    {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.bob), ctx.home)
    assert has_element?(view, "#spec-attention-approve-#{ctx.ident}")

    {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1, wake: false})
    eventually(fn -> !has_element?(view, "#spec-attention") end)
  end
end

defmodule Helmsman.Links.RunScopeTest do
  use Helmsman.DataCase, async: true

  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Links
  alias Helmsman.Links.Link

  setup do
    ctx = dispatch_fixture()
    [own, other, third] = for _ <- 1..3, do: task_fixture(ctx.alice_scope, ctx.project.key)

    run =
      run_fixture(ctx.agent, %{
        task_id: own.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    Map.merge(ctx, %{own: own, other: other, third: third, run: run, scope: scope})
  end

  defp link_count, do: Repo.aggregate(Link, :count)

  test "replacing another open task is forbidden", ctx do
    for status <- [:new, :in_progress] do
      set_status!(ctx.other, status)

      assert Links.add(ctx.scope, ctx.own.ident, ctx.other.ident, "replaces") ==
               {:error, {:forbidden, {:cancels_other_task, ctx.other.ident, ctx.own.ident}}}

      assert status_of(ctx.other) == status
      assert link_count() == 0
    end
  end

  test "replacing its own task cancels it", ctx do
    assert {:ok, _} = Links.add(ctx.scope, ctx.other.ident, ctx.own.ident, "replaces")
    assert status_of(ctx.own) == :cancelled
    assert link_count() == 1
  end

  test "replacing a finished task only records the link", ctx do
    set_status!(ctx.other, :done)
    assert {:ok, _} = Links.add(ctx.scope, ctx.own.ident, ctx.other.ident, "replaces")
    assert status_of(ctx.other) == :done
    assert link_count() == 1
  end

  test "a link without its own task is forbidden", ctx do
    assert Links.add(ctx.scope, ctx.other.ident, ctx.third.ident, "depends_on") ==
             {:error, :forbidden}

    assert Links.remove(ctx.scope, ctx.other.ident, ctx.third.ident, "depends_on") ==
             {:error, :forbidden}

    assert link_count() == 0
  end

  test "depends_on in both directions", ctx do
    assert {:ok, %{blocked: true}} =
             Links.add(ctx.scope, ctx.own.ident, ctx.other.ident, "depends_on")

    assert {:ok, %{blocked: true}} =
             Links.add(ctx.scope, ctx.third.ident, ctx.own.ident, "depends_on")

    assert link_count() == 2
  end

  test "removing a replaces link is not limited", ctx do
    set_status!(ctx.other, :done)
    {:ok, _} = Links.add(ctx.alice_scope, ctx.own.ident, ctx.other.ident, "replaces")
    set_status!(ctx.other, :in_progress)

    assert {:ok, %{links: []}} =
             Links.remove(ctx.scope, ctx.own.ident, ctx.other.ident, "replaces")
  end

  test "a run without write_task may not link", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.own.id, status: :running, capabilities: ["read"]})
    {scope, _token} = run_scope_fixture(run)

    for fun <- [&Links.add/4, &Links.remove/4], type <- ["depends_on", "replaces"] do
      assert fun.(scope, ctx.own.ident, ctx.other.ident, type) == {:error, :forbidden}
    end

    assert link_count() == 0
  end
end

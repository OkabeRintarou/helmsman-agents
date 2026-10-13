defmodule HelmsmanWeb.TaskLive.CollabMergeWaitTest do
  # add-collaboration-ui 2.1: web-collaboration「在等合并」.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.DependencyFixtures, only: [put_status!: 2]
  import Helmsman.ProjectsFixtures
  import Helmsman.PullRequestFixtures

  alias Helmsman.Links

  test "在等合并", %{conn: conn} do
    ctx = pr_fixture()
    pushed_run(ctx, sha("a"), sha("b"))
    put_status!(ctx.task, :verified)
    web = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, web.ident, ctx.task.ident, "depends_on")

    {:ok, view, _} = live(log_in_user(conn, ctx.alice), "/w/#{ctx.workspace.slug}/t/#{web.ident}")

    assert view |> element("#task-blocked-tip") |> render() =~ "#{ctx.task.ident} 代码还没合并"
  end
end

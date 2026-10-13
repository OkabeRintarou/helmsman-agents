defmodule HelmsmanWeb.TaskLive.CollabEpicWindowTest do
  # add-collaboration-ui 4.4 (spec review 1 P2): a sibling step that finishes between
  # locating the epic and subscribing to its project is not missed. Uses the
  # `:collab_after_locate` hook (application env), hence not async.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures

  alias Helmsman.Tasks

  setup %{conn: conn} do
    ctx = links_fixture()
    on_exit(fn -> Application.delete_env(:helmsman, :collab_after_locate) end)
    Map.merge(ctx, %{conn: conn, slug: ctx.workspace.slug})
  end

  defp epic!(ctx, key \\ "BOS"), do: task_fixture(ctx.owner, key, %{kind: "epic"})
  defp step!(ctx, key, epic), do: task_fixture(ctx.owner, key, %{epic: epic.ident})

  # Finishes `sibling` once, when the page locates `epic`.
  defp finish_on_locate(ctx, epic, sibling) do
    {:ok, once} = Agent.start_link(fn -> true end)
    owner = ctx.owner

    Application.put_env(:helmsman, :collab_after_locate, fn ident ->
      if ident == epic.ident and Agent.get_and_update(once, &{&1, false}) do
        {:ok, _} = Tasks.transition(owner, sibling.ident, "in_progress")
        {:ok, _} = Tasks.transition(owner, sibling.ident, "done")
      end
    end)
  end

  test "打开页面的同时兄弟步骤完成", ctx do
    epic = epic!(ctx)
    step = step!(ctx, "WEB", epic)
    sibling = step!(ctx, "BOS", epic)
    finish_on_locate(ctx, epic, sibling)

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.alice.user), "/w/#{ctx.slug}/t/#{step.ident}")
    assert has_element?(view, ~s(#task-epic-field-progress[data-progress="1/2"]))
  end

  test "改归属的同时新 Epic 的步骤完成", ctx do
    # The new epic is in another project: the page must move to another topic.
    old = epic!(ctx, "BOS")
    new = epic!(ctx, "WEB")
    step = step!(ctx, "WEB", old)
    old_sibling = step!(ctx, "BOS", old)
    new_sibling = step!(ctx, "WEB", new)
    finish_on_locate(ctx, new, new_sibling)

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.alice.user), "/w/#{ctx.slug}/t/#{step.ident}")
    render_click(view, "edit_field", %{field: "description"})
    render_change(view, "draft_field", %{field: "description", value: "草稿", session: "1"})

    view |> element("#task-epic-edit") |> render_click()

    id =
      view
      |> element("#epic-panel-portal")
      |> render()
      |> then(&Regex.run(~r/id="(epic-picker-\d+)"/, &1))
      |> List.last()

    {:ok, task} = Tasks.get(ctx.owner, new.ident)
    send(view.pid, {:task_picked, id, Tasks.summary(task)})
    render_click(view, "collab_epic_submit", %{})

    assert has_element?(view, "#task-epic-field", new.ident)
    assert has_element?(view, ~s(#task-epic-field-progress[data-progress="1/2"]))

    assert %{draft: "草稿", updated?: false} =
             :sys.get_state(view.pid).socket.assigns.editing["description"]

    {:ok, _} = Tasks.transition(ctx.owner, old_sibling.ident, "in_progress")
    {:ok, _} = Tasks.transition(ctx.owner, old_sibling.ident, "done")
    assert has_element?(view, ~s(#task-epic-field-progress[data-progress="1/2"]))
    assert has_element?(view, "#task-epic-field", new.ident)
  end
end

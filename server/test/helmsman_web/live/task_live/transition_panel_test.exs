defmodule HelmsmanWeb.TaskLive.TransitionPanelTest do
  use HelmsmanWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.PortalHelpers
  alias Helmsman.Tasks

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Tasks.transition(ctx.alice_scope, task.ident, "in_progress", %{})
    Map.put(ctx, :task, task)
  end

  defp host(conn, scope, ident),
    do: live_isolated(conn, __MODULE__.Host, session: %{"scope" => scope, "ident" => ident})

  test "minimal host opens validates and submits with domain authority", ctx do
    {:ok, view, _} = host(ctx.conn, ctx.alice_scope, ctx.task.ident)

    render_click(with_target(view, "#panel-host"), "open_transition", %{
      from: "in_progress",
      to: "done"
    })

    assert in_portal?(view, "transition-panel", "#transition-panel-title", "完成 #{ctx.task.ident}")

    render_submit(with_target(view, "#panel-host"), "submit_transition", %{
      transition: %{result: "passed", command: ""}
    })

    assert in_portal?(view, "transition-panel", "#transition-command-error", "不能为空")

    render_submit(with_target(view, "#panel-host"), "submit_transition", %{
      transition: %{result: "passed", command: "mix test"}
    })

    assert has_element?(view, "#result", "done")
    assert {:ok, %{status: :done}} = Tasks.get(ctx.alice_scope, ctx.task.ident)
  end

  test "stale state blocks submission and viewer cannot open", ctx do
    {:ok, view, _} = host(ctx.conn, ctx.alice_scope, ctx.task.ident)

    render_click(with_target(view, "#panel-host"), "open_transition", %{
      from: "in_progress",
      to: "done"
    })

    Tasks.transition(ctx.alice_scope, ctx.task.ident, "cancelled", %{comment: "cancel"})

    render_submit(with_target(view, "#panel-host"), "submit_transition", %{
      transition: %{result: "none"}
    })

    assert in_portal?(view, "transition-panel", "#transition-panel-error", "任务状态已变为已撤销")
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, readonly, _} = host(ctx.conn, viewer, ctx.task.ident)

    render_click(with_target(readonly, "#panel-host"), "open_transition", %{
      from: "cancelled",
      to: "new"
    })

    refute open?(readonly, "transition-panel")
  end

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket),
      do:
        {:ok,
         Phoenix.Component.assign(socket,
           scope: session["scope"],
           ident: session["ident"],
           result: ""
         )}

    def handle_info({:transition_panel, result, _ident}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :result, to_string(result))}

    def render(assigns) do
      ~H"""
      <div>
        <span id="result">{@result}</span><.live_component
          module={HelmsmanWeb.TaskLive.TransitionPanel}
          id="host-transition"
          ident={@ident}
          scope={@scope}
          version={1}
          candidates={[]}
        />
      </div>
      """
    end
  end
end

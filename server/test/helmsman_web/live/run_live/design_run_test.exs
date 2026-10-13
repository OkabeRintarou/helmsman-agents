defmodule HelmsmanWeb.RunLive.DesignRunTest do
  @moduledoc """
  Spec web-runs 创建对话的运行 (add-agent-conversation-ui D13): the trigger of a design
  run on the agent page and the run page (no link, no conversation ID, the conversation
  never read), its execution log as usual, and no retry.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures

  import Ecto.Query

  alias Helmsman.{AgentDesigns, Repo}
  alias Helmsman.Runs.Run

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {bob, _} = member_scope_fixture(ctx.workspace)
    alice_name = human_actor(ctx.workspace, ctx.alice).name

    {:ok, design} =
      AgentDesigns.start(ctx.alice_scope, %{helper: "keel/dev", message: "ALICE-PRIVATE-IDEA"})

    run = Repo.get!(Run, design.current_run.id)
    now = DateTime.utc_now()

    set_run!(run.id,
      status: :running,
      daemon_id: daemon_of(ctx.agent).id,
      claimed_at: now,
      started_at: now
    )

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      alice_name: alice_name,
      design_id: design.id,
      run: run,
      path: "/w/#{ctx.workspace.slug}/runs/#{run.id}"
    })
  end

  defp open(ctx, user, path \\ nil), do: live(log_in_user(ctx.conn, user), path || ctx.path)

  defp label(ctx), do: "#{ctx.alice_name} 的创建对话"

  test "起草 Agent 的运行列表", ctx do
    {:ok, view, _html} = open(ctx, ctx.bob, "/w/#{ctx.workspace.slug}/agents/keel/dev")
    html = render(view)
    assert html =~ label(ctx)
    refute has_element?(view, "a", label(ctx))
    refute html =~ "agent-design"
    refute html =~ "ALICE-PRIVATE-IDEA"
  end

  test "另一位成员查看设计运行", ctx do
    append!(ctx.agent, ctx.run.id, [event(1, :text, %{text: "建议用 sonnet"})])
    finish!(ctx.agent, ctx.run.id, :succeeded)

    {:ok, view, html} = open(ctx, ctx.bob)
    assert has_element?(view, "#run-log-events", "建议用 sonnet")
    assert has_element?(view, "[data-triggers]", label(ctx))
    refute has_element?(view, "[data-triggers] a")
    refute html =~ "agent-design"
    refute html =~ "ALICE-PRIVATE-IDEA"
    refute render(view) =~ "agent-design"
    refute render(view) =~ "ALICE-PRIVATE-IDEA"

    subscribed = Registry.lookup(Helmsman.PubSub, "agent_design:#{ctx.design_id}")
    refute Enum.any?(subscribed, fn {pid, _} -> pid == view.pid end)
  end

  test "失败的设计运行没有重试", ctx do
    finish!(ctx.agent, ctx.run.id, :failed, %{failure_reason: :timeout})

    {:ok, view, _html} = open(ctx, ctx.alice)
    assert has_element?(view, "#run-properties", "超时")
    refute has_element?(view, "#run-retry")
    refute has_element?(view, "[phx-click=retry_run]")
  end

  # A stale page (a retry button rendered before) asks anyway: the domain refuses.
  test "过时页面上的重试", ctx do
    finish!(ctx.agent, ctx.run.id, :failed, %{failure_reason: :timeout})
    {:ok, view, _html} = open(ctx, ctx.alice)

    html = render_click(view, "retry_run", %{"id" => to_string(ctx.run.id)})
    assert html =~ "创建对话的运行不能重试，请在对话里重新发送"
    assert Repo.aggregate(from(r in Run, where: r.agent_id == ^ctx.agent.id), :count) == 1
  end
end

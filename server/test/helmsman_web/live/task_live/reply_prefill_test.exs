defmodule HelmsmanWeb.TaskLive.ReplyPrefillTest do
  @moduledoc """
  Spec web-feedback 回复时预填提及 (add-nested-feedback-replies D10, D11, tasks 2.3), with a
  managed `keel/dev` alice may trigger (`dispatch_fixture/0`).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Actors, Feedback}

  @panel "feedback-panel"

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      bob_scope: bob_scope,
      task: task,
      agent_scope: %{ctx.alice_scope | actor: ctx.agent},
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, user) do
    {:ok, view, _} = live(log_in_user(ctx.conn, user), ctx.path)
    view
  end

  defp add(ctx, scope, content, attrs \\ %{}) do
    {:ok, entry} = Feedback.add(scope, ctx.task.ident, Map.merge(%{content: content}, attrs))
    entry
  end

  defp editor_text(view) do
    view
    |> portal(@panel)
    |> LazyHTML.query("textarea[id^=feedback-editor-input-]")
    |> LazyHTML.text()
  end

  defp session(view), do: portal_attr(view, @panel, "input[name=editor_session]", "value")

  defp submit(view, params),
    do: render_submit(view, "submit_feedback", %{feedback: params, editor_session: session(view)})

  defp reply(view, seq), do: view |> element("#feedback-#{seq}-reply") |> render_click()

  defp reply_runs(ctx), do: Enum.filter(runs_of(ctx.task.id), &(&1.lane == :reply))

  test "回复 Agent 的评论: @keel/dev is prefilled and wakes it once", ctx do
    add(ctx, ctx.agent_scope, "已复现")
    view = open(ctx, ctx.alice)

    reply(view, 1)
    assert open?(view, @panel)
    assert editor_text(view) == "@keel/dev "

    submit(view, %{kind: "comment", content: "@keel/dev 改用方案 B"})
    refute open?(view, @panel)

    assert [run] = reply_runs(ctx)
    assert [%{"kind" => "mention", "by_actor_id" => by}] = run.triggers
    assert by == ctx.alice_scope.actor.id
    assert has_element?(view, "#feedback-thread-1-replies #feedback-2[data-kind=comment]")
  end

  test "删除预填: no mention, no run, still a reply", ctx do
    add(ctx, ctx.agent_scope, "已复现")
    view = open(ctx, ctx.alice)

    reply(view, 1)
    submit(view, %{kind: "comment", content: "改用方案 B"})

    assert reply_runs(ctx) == []
    entry = Feedback.Entry |> Helmsman.Repo.get_by!(task_id: ctx.task.id, seq: 2)
    assert entry.mentions == []
    assert entry.reply_to_seq == 1
  end

  test "回复人的评论: @bob is prefilled, marks bob, starts nothing", ctx do
    bob = ctx.bob_scope.actor.name
    add(ctx, ctx.bob_scope, "我觉得不对")
    view = open(ctx, ctx.alice)

    reply(view, 1)
    assert editor_text(view) == "@#{bob} "
    submit(view, %{kind: "comment", content: "@#{bob} 哪里不对？"})

    entry = Feedback.Entry |> Helmsman.Repo.get_by!(task_id: ctx.task.id, seq: 2)
    assert ctx.bob_scope.actor.id in entry.mentions
    assert runs_of(ctx.task.id) == []
  end

  test "回复自己的记录或系统备注: nothing prefilled", ctx do
    add(ctx, ctx.alice_scope, "我的备注")
    {:ok, system} = Actors.ensure_system(ctx.workspace)
    add(ctx, %{ctx.alice_scope | actor: system}, "自动备注")
    view = open(ctx, ctx.alice)

    reply(view, 1)
    assert editor_text(view) == ""
    render_click(view, "close_feedback", %{})

    view = open(ctx, ctx.alice)
    reply(view, 2)
    assert editor_text(view) == ""
  end

  test "回答, 添加 and 修订 prefill nothing", ctx do
    add(ctx, ctx.agent_scope, "A 还是 B？", %{kind: "question"})
    add(ctx, ctx.alice_scope, "原文")

    view = open(ctx, ctx.alice)
    view |> element("#feedback-1-answer") |> render_click()
    assert editor_text(view) == ""

    view = open(ctx, ctx.alice)
    view |> element("#feedback-add") |> render_click()
    assert editor_text(view) == ""

    view = open(ctx, ctx.alice)
    render_click(view, "open_feedback", %{"mode" => "revise", "target" => "#{ctx.task.ident}#2"})
    assert editor_text(view) == "原文"
  end

  test "修订带预填提及的回复: kept mentions start nothing, a new one exactly one", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/qa",
      access: "workspace",
      runtime_id: profile(ctx.agent).runtime_id
    })

    add(ctx, ctx.agent_scope, "已复现")
    view = open(ctx, ctx.alice)
    reply(view, 1)
    submit(view, %{kind: "comment", content: "@keel/dev 改用方案 B"})
    assert length(reply_runs(ctx)) == 1

    {:ok, _} =
      Feedback.revise(ctx.alice_scope, "#{ctx.task.ident}#2", %{content: "@keel/dev 改用方案 C"})

    assert length(reply_runs(ctx)) == 1

    {:ok, _} =
      Feedback.revise(ctx.alice_scope, "#{ctx.task.ident}#3", %{
        content: "@keel/dev @keel/qa 改用方案 C"
      })

    qa = agent_actor(ctx.workspace, "keel/qa")
    assert [run] = Enum.filter(reply_runs(ctx), &(&1.agent_id == qa.id))
    assert [%{"kind" => "mention"}] = run.triggers
    assert length(reply_runs(ctx)) == 2
  end
end

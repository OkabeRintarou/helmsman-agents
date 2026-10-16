defmodule HelmsmanWeb.TaskLive.CollabDispatchTest do
  # add-collaboration-ui 5.2, 5.3: web-collaboration「Feedback 的触发结果」and
  # 「提及前的可触发提示」.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import HelmsmanWeb.PortalHelpers

  import Ecto.Query, only: [from: 2]

  alias Helmsman.{Feedback, Repo}

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      bob_scope: bob_scope,
      task: task,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, user) do
    {:ok, view, _} = live(log_in_user(ctx.conn, user), ctx.path)
    view
  end

  test "被拒的提及", ctx do
    {:ok, _} = Feedback.add(ctx.bob_scope, ctx.task.ident, %{content: "@keel/dev 看一下"})
    view = open(ctx, ctx.alice)

    assert has_element?(view, "#feedback-1-dispatch-0[data-skipped][data-agent='keel/dev']", "提及")
    assert has_element?(view, "#feedback-1-dispatch-0", "触发者无权触发它")

    mention =
      view
      |> element("#feedback-1")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("span.hm-mention[data-skipped]")

    assert LazyHTML.attribute(mention, "data-actor") == ["keel/dev"]
    assert LazyHTML.attribute(mention, "title") == ["触发者无权触发它"]
  end

  test "排上队的提及", ctx do
    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/dev 看一下"})
    [%{run_id: run_id, result: "queued"}] = Feedback.view(entry).dispatch
    view = open(ctx, ctx.alice)

    assert has_element?(view, "#feedback-1-dispatch-0[data-result=queued]", "提及")
    assert has_element?(view, ~s(#feedback-1-dispatch-0 a[href$="?run=#{run_id}"]), "keel/dev")
    refute has_element?(view, "#feedback-1 span.hm-mention[data-skipped]")
    assert has_element?(view, "#feedback-1 span.hm-mention[data-actor='keel/dev']")
  end

  # add-nested-feedback-replies 2.3: web-collaboration「被覆盖的提及」.
  describe "被覆盖的提及" do
    # keel/dev asks #1 in a reply-lane run alice started.
    defp question!(ctx) do
      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.task.id,
          status: :running,
          lane: :reply,
          root_initiator_user_id: ctx.alice.id,
          capabilities: ["read", "write_task"]
        })

      {scope, _} = run_scope_fixture(run)
      {:ok, _} = Feedback.add(scope, ctx.task.ident, %{kind: "question", content: "A 还是 B？"})
    end

    # #1 written outside a run: an answer has no grant.
    defp orphan_question!(ctx) do
      Repo.insert!(%Feedback.Entry{
        workspace_id: ctx.task.workspace_id,
        task_id: ctx.task.id,
        seq: 1,
        thread_seq: 1,
        author_id: ctx.agent.id,
        kind: :question,
        content: "A 还是 B？"
      })

      Repo.update_all(from(t in Helmsman.Tasks.Task, where: t.id == ^ctx.task.id),
        set: [feedback_seq: 1, feedback_count: 1, open_question: true]
      )
    end

    defp answer!(ctx, scope) do
      {:ok, entry} =
        Feedback.add(scope, ctx.task.ident, %{kind: "answer", content: "@keel/dev 用方案 B"})

      Feedback.view(entry).dispatch
    end

    test "回答覆盖提及: the answer links to its run; the mention says so, not muted", ctx do
      question!(ctx)
      [%{trigger: "answer", run_id: run_id}, %{reason: "covered"}] = answer!(ctx, ctx.alice_scope)
      view = open(ctx, ctx.alice)

      assert has_element?(view, ~s(#feedback-2-dispatch-0 a[href$="?run=#{run_id}"]), "keel/dev")
      assert has_element?(view, "#feedback-2-dispatch-0", "回答")

      assert has_element?(
               view,
               "#feedback-2-dispatch-1[data-covered]:not([data-skipped])",
               "已由这条记录的回答唤醒"
             )

      assert has_element?(view, "#feedback-2-dispatch-1", "提及")
      refute has_element?(view, "#feedback-2 span.hm-mention[data-skipped]")
      assert has_element?(view, "#feedback-2 span.hm-mention[data-actor='keel/dev']")
    end

    test "回答被跳过、提及唤醒: the reason in grey, the mention links to its run", ctx do
      orphan_question!(ctx)

      [%{trigger: "answer", reason: "no_grant"}, %{trigger: "mention", run_id: run_id}] =
        answer!(ctx, ctx.alice_scope)

      view = open(ctx, ctx.alice)

      assert has_element?(view, "#feedback-2-dispatch-0[data-skipped]", "回答")
      assert has_element?(view, ~s(#feedback-2-dispatch-1 a[href$="?run=#{run_id}"]), "keel/dev")
      refute render(view) =~ "已由这条记录"
      refute has_element?(view, "#feedback-2 span.hm-mention[data-skipped]")
    end

    test "都被跳过: both in grey with their reasons, the @ muted", ctx do
      orphan_question!(ctx)

      [%{reason: "no_grant"}, %{reason: "unauthorized"}] = answer!(ctx, ctx.bob_scope)
      view = open(ctx, ctx.alice)

      assert has_element?(view, "#feedback-2-dispatch-0[data-skipped]", "回答")
      assert has_element?(view, "#feedback-2-dispatch-1[data-skipped]", "触发者无权触发它")
      refute has_element?(view, "[data-covered]")

      assert has_element?(
               view,
               "#feedback-2 span.hm-mention[data-skipped][data-actor='keel/dev']"
             )
    end
  end

  describe "提及前的可触发提示" do
    defp mentions(view, editor, q) do
      cid = portal_attr(view, "feedback-panel", "##{editor}", "data-phx-component")
      session = portal_attr(view, "feedback-panel", "input[name=editor_session]", "value")

      render_hook(with_target(view, String.to_integer(cid)), "mention_query", %{
        q: q,
        session: session
      })

      view |> portal("feedback-panel") |> LazyHTML.query("##{editor}-mentions li")
    end

    test "无权的 Agent and an external one", ctx do
      agent_fixture(ctx.workspace, ctx.alice, "keel/cli")
      view = open(ctx, ctx.bob)
      view |> element("#feedback-add") |> render_click()

      items = mentions(view, "feedback-editor", "keel")
      by_name = Map.new(items, &{hd(LazyHTML.attribute(&1, "data-name")), &1})

      assert LazyHTML.attribute(by_name["keel/dev"], "data-muted") == ["true"]
      assert LazyHTML.text(by_name["keel/dev"]) =~ "@ 不会启动它：你无权触发 keel/dev"
      assert LazyHTML.text(by_name["keel/cli"]) =~ "外接 Agent，@ 不会唤醒它"
    end

    test "a dispatchable agent has no note; the description editor never has one", ctx do
      view = open(ctx, ctx.alice)
      view |> element("#feedback-add") |> render_click()
      item = mentions(view, "feedback-editor", "keel")
      assert LazyHTML.attribute(item, "data-name") == ["keel/dev"]
      assert LazyHTML.attribute(item, "data-muted") == []

      assert Enum.all?(
               :sys.get_state(view.pid).socket.assigns.assignable,
               &(not Map.has_key?(&1, :note))
             )
    end
  end
end

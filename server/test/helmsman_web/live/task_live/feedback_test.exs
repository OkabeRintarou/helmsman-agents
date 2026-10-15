defmodule HelmsmanWeb.TaskLive.FeedbackTest do
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Events, Feedback, Repo, Tasks}
  alias Helmsman.Workspaces.Membership

  @panel "feedback-panel"

  setup %{conn: conn} do
    alice = user_fixture()
    ws = workspace_fixture(alice)
    alice_scope = workspace_scope_fixture(alice, ws)

    scopes =
      for role <- [:bob, :viewer], into: %{alice: alice_scope} do
        user = user_fixture()
        member_fixture(ws, user, if(role == :viewer, do: :viewer, else: :member))
        {role, workspace_scope_fixture(user, ws)}
      end

    agent = agent_fixture(ws, alice, "keel/dev")
    scopes = Map.put(scopes, :agent, %{alice_scope | actor: agent})

    project_fixture(alice_scope, key: "BOS", name: "Bosun")
    task_fixture(alice_scope, "BOS")

    %{conn: conn, ws: ws, scopes: scopes, path: "/w/#{ws.slug}/t/BOS-1", alice: alice}
  end

  defp as(ctx, role), do: log_in_user(ctx.conn, ctx.scopes[role].user)

  # %{id: "BOS-1#N", seq: N}
  defp add(ctx, role, kind, content) do
    {:ok, entry} = Feedback.add(ctx.scopes[role], "BOS-1", %{kind: kind, content: content})
    %{id: "BOS-1##{entry.seq}", seq: entry.seq}
  end

  # Writes from another process, as an agent through MCP would.
  defp add_elsewhere(ctx, role, kind, content),
    do: Task.async(fn -> add(ctx, role, kind, content) end) |> Task.await()

  defp revise(ctx, role, id, content) do
    {:ok, entry} = Feedback.revise(ctx.scopes[role], id, %{content: content})
    %{id: "BOS-1##{entry.seq}", seq: entry.seq}
  end

  # Components inside overlays are teleported; target the editor by its cid.
  defp editor(view) do
    cid = portal_attr(view, @panel, "#feedback-editor", "data-phx-component")
    with_target(view, String.to_integer(cid))
  end

  defp session(view), do: portal_attr(view, @panel, "input[name=editor_session]", "value")

  defp change(view, params),
    do: render_change(view, "feedback_change", %{feedback: params, editor_session: session(view)})

  defp submit(view, params),
    do: render_submit(view, "submit_feedback", %{feedback: params, editor_session: session(view)})

  defp open_add(view), do: view |> element("#feedback-add") |> render_click()
  defp open_revise(view, seq), do: view |> element("#feedback-#{seq}-revise") |> render_click()

  defp editor_input(view) do
    view
    |> portal(@panel)
    |> LazyHTML.query("textarea[id^=feedback-editor-input-]")
    |> Enum.map(fn node -> {hd(LazyHTML.attribute(node, "id")), LazyHTML.text(node)} end)
    |> List.first()
  end

  defp entries, do: Repo.all(Feedback.Entry)

  defp task_topic(ctx) do
    {:ok, task} = Tasks.get(ctx.scopes.alice, "BOS-1")
    Events.topic(:task, task.id)
  end

  describe "timeline" do
    test "threads and earlier versions (线索与早期版本)", ctx do
      add(ctx, :alice, "comment", "已复现")
      %{id: question} = add(ctx, :agent, "question", "用哪个方案？")
      add(ctx, :bob, "answer", "方案 A")
      revise(ctx, :alice, question, "用哪个方案？A 还是 B")

      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      cards =
        view
        |> element("#feedback-threads")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#feedback-threads > li > article")
        |> LazyHTML.attribute("id")

      assert cards == ["feedback-1", "feedback-4", "feedback-3"]
      assert has_element?(view, ~s(#feedback-4 [data-supersedes][href="#feedback-2"]), "修订自 #2")
      assert has_element?(view, "#feedback-thread-2-history summary", "早期版本（1）")
      assert has_element?(view, "#feedback-thread-2-history #feedback-2[data-status=superseded]")
      assert has_element?(view, "#feedback-2 [data-superseded]", "已作废，被")
      assert has_element?(view, ~s(#feedback-2 [data-superseded] a[href="#feedback-4"]))
      refute has_element?(view, "#feedback-2-menu-trigger")
      assert has_element?(view, ~s(#feedback-3[data-kind=answer] [data-kind-badge]), "回答")
      assert has_element?(view, "#feedback-1 .hm-prose", "已复现")
      assert has_element?(view, ~s(#feedback-1 button[data-copy="BOS-1#1"]))

      for seq <- 1..4, do: assert(has_element?(view, "article#feedback-#{seq}"))
    end

    test "no feedback (没有 Feedback)", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      assert has_element?(view, "#feedback-empty", "还没有 Feedback")
      assert has_element?(view, "#feedback-add", "添加 Feedback")

      {:ok, view, _html} = live(as(ctx, :viewer), ctx.path)
      assert has_element?(view, "#feedback-empty")
      refute has_element?(view, "#feedback-add")
    end

    test "feedback the system wrote has no menu", ctx do
      {:ok, system} = Helmsman.Actors.ensure_system(ctx.ws)

      system_ctx = %{
        ctx
        | scopes: Map.put(ctx.scopes, :system, %{ctx.scopes.alice | actor: system})
      }

      add(system_ctx, :system, "comment", "自动备注")

      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)
      assert has_element?(view, "#feedback-1[data-system]")
      refute has_element?(view, "#feedback-1-menu-trigger")
    end

    test "each record is rendered once; a refresh renders only new ones", ctx do
      add(ctx, :alice, "comment", "一")
      add(ctx, :alice, "comment", "二")

      test_pid = self()
      handler = "feedback-render-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:helmsman_web, :feedback, :render],
        fn _event, _measurements, meta, _ -> send(test_pid, {:rendered, meta.id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      _ = render(view)
      flush_rendered()

      add_elsewhere(ctx, :agent, "comment", "三")
      add_elsewhere(ctx, :agent, "review", "四")
      assert has_element?(view, "#feedback-4", "四")

      assert flush_rendered() |> Enum.sort() == ["BOS-1#3", "BOS-1#4"]
    end
  end

  defp flush_rendered(acc \\ []) do
    receive do
      {:rendered, id} -> flush_rendered([id | acc])
    after
      50 -> acc
    end
  end

  describe "writing" do
    test "a comment (写评论)", ctx do
      for content <- ~w(一 二 三), do: add(ctx, :alice, "comment", content)
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      open_add(view)
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#feedback-panel-title", "添加 Feedback")
      assert portal_attr(view, @panel, ~s(input[name="feedback[kind]"][value=comment]), "checked")

      submit(view, %{kind: "comment", content: "已复现"})

      refute open?(view, @panel)
      assert has_element?(view, "#feedback-4[data-kind=comment]", "已复现")
      assert_push_event(view, "hm:scroll-to", %{id: "feedback-4"})
    end

    test "answering a question (回答提问)", ctx do
      add(ctx, :alice, "comment", "c")
      %{seq: q} = add_elsewhere(ctx, :agent, "question", "用方案 A 还是 B？")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      assert has_element?(view, "#task-open-question", "待回答")

      view |> element("#feedback-#{q}-answer") |> render_click()
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#feedback-panel-title", "回答 BOS-1##{q}")
      assert in_portal?(view, @panel, "#feedback-quote", "用方案 A 还是 B？")
      refute in_portal?(view, @panel, ~s(input[name="feedback[kind]"]))

      submit(view, %{content: "用方案 B"})
      assert has_element?(view, "#feedback-3[data-kind=answer]", "用方案 B")
      refute has_element?(view, "#task-open-question")
    end

    test "empty content (空内容)", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)
      submit(view, %{kind: "comment", content: ""})

      assert in_portal?(view, @panel, "#feedback-editor-error", "不能为空")
      assert open?(view, @panel)
      assert entries() == []
    end

    test "viewers read without entries (viewer)", ctx do
      add(ctx, :alice, "comment", "mine")
      add(ctx, :agent, "question", "q?")
      {:ok, view, _html} = live(as(ctx, :viewer), ctx.path)

      assert has_element?(view, "#feedback-1", "mine")
      refute has_element?(view, "#feedback-add")
      refute has_element?(view, "#feedback-2-answer")
      refute has_element?(view, "#feedback-1-revise")

      render_click(view, "open_feedback", %{"mode" => "add"})
      refute open?(view, @panel)
    end

    test "a write refused by the domain shows 没有权限执行此操作", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)

      Repo.update_all(
        from(m in Membership, where: m.user_id == ^ctx.scopes.bob.user.id),
        set: [role: :viewer]
      )

      submit(view, %{kind: "comment", content: "x"})
      assert in_portal?(view, @panel, "#feedback-panel-error", "没有权限执行此操作")
      assert entries() == []
    end

    test "submitting from the preview writes the textarea's text", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)

      render_hook(editor(view), "set_mode", %{
        "mode" => "preview",
        "value" => "**预览中提交**",
        "session" => session(view)
      })

      assert in_portal?(view, @panel, "#feedback-editor-preview strong", "预览中提交")
      submit(view, %{kind: "comment", content: "**预览中提交**"})

      refute open?(view, @panel)
      assert has_element?(view, "#feedback-1 strong", "预览中提交")
    end

    test "too long content keeps the preview and reports under the editor", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)
      {input, _} = editor_input(view)
      long = String.duplicate("a", 65_537)

      render_hook(editor(view), "set_mode", %{
        "mode" => "preview",
        "value" => long,
        "session" => session(view)
      })

      submit(view, %{kind: "comment", content: long})
      assert in_portal?(view, @panel, "#feedback-editor-error", "不能超过 64 KB")
      assert in_portal?(view, @panel, ~s(#feedback-editor-tab-preview[aria-selected="true"]))
      assert {^input, _} = editor_input(view)
    end
  end

  describe "replying (add-feedback-replies)" do
    defp add_reply(ctx, role, kind, content, reply_to) do
      {:ok, entry} =
        Feedback.add(ctx.scopes[role], "BOS-1", %{
          kind: kind,
          content: content,
          reply_to: reply_to
        })

      %{id: "BOS-1##{entry.seq}", seq: entry.seq}
    end

    defp name(ctx, role), do: ctx.scopes[role].actor.name

    test "回复 opens the editor on the record it replies to", ctx do
      add(ctx, :agent, "comment", "已复现\n第二行")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      view |> element("#feedback-1-reply") |> render_click()
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#feedback-panel-title", "回复 BOS-1#1")
      assert in_portal?(view, @panel, "#feedback-quote", "@keel/dev")
      assert in_portal?(view, @panel, "#feedback-quote", "已复现")
      assert portal_attr(view, @panel, ~s(input[name="feedback[kind]"][value=comment]), "checked")

      submit(view, %{kind: "comment", content: "我也遇到了"})
      refute open?(view, @panel)
      assert has_element?(view, "#feedback-2[data-kind=comment]", "我也遇到了")
      assert_push_event(view, "hm:scroll-to", %{id: "feedback-2"})
    end

    test "no 回复 for readers, nor on a superseded record", ctx do
      %{id: id} = add(ctx, :alice, "comment", "原文")
      revise(ctx, :alice, id, "新文")

      {:ok, view, _html} = live(as(ctx, :viewer), ctx.path)
      refute has_element?(view, "#feedback-2-reply")
      render_click(view, "open_feedback", %{"mode" => "reply", "target" => "BOS-1#2"})
      refute open?(view, @panel)

      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      assert has_element?(view, "#feedback-2-reply")
      refute has_element?(view, "#feedback-1-reply")
      render_click(view, "open_feedback", %{"mode" => "reply", "target" => "BOS-1#1"})
      refute open?(view, @panel)
    end

    test "a reply nests under the record it replies to, without a 回复 @… line", ctx do
      add(ctx, :alice, "comment", "已复现")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      view |> element("#feedback-1-reply") |> render_click()
      submit(view, %{kind: "comment", content: "我也遇到了"})
      assert has_element?(view, "#feedback-thread-1-replies > ol > li > #feedback-2")
      refute has_element?(view, "#feedback-2-reply-to")

      view |> element("#feedback-2-reply") |> render_click()
      submit(view, %{kind: "comment", content: "第三条"})
      assert has_element?(view, "#feedback-thread-2-replies > ol > li > #feedback-3")
      assert has_element?(view, "#feedback-thread-2[data-depth='1']")
      assert has_element?(view, "#feedback-thread-3[data-depth='2']")
      refute has_element?(view, "#feedback-3-reply-to")
    end

    test "a reply written elsewhere shows at once; a revised target shows its current version",
         ctx do
      %{id: root} = add(ctx, :alice, "comment", "原文")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      Task.async(fn -> add_reply(ctx, :agent, "comment", "MCP 的回复", root) end)
      |> Task.await()

      assert has_element?(view, "#feedback-thread-1-replies #feedback-2", "MCP 的回复")
      assert has_element?(view, "#feedback-thread-1-replies[data-count='1']")

      # The revised target keeps its place; the reply stays under it, no label (D7).
      Task.async(fn -> revise(ctx, :alice, root, "修订后") end) |> Task.await()

      assert has_element?(view, "#feedback-thread-1 > #feedback-3", "修订后")
      assert has_element?(view, "#feedback-thread-1-replies > ol > li > #feedback-2")
      refute has_element?(view, "#feedback-2-reply-to")
    end

    test "a deep reply flattened at depth 3 links to its target, revised or not", ctx do
      %{id: first} = add(ctx, :alice, "comment", "一")

      ids =
        Enum.reduce(2..5, [first], fn i, [last | _] = acc ->
          [add_reply(ctx, :bob, "comment", "第#{i}", last).id | acc]
        end)

      [_fifth, fourth | _] = ids
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)

      assert has_element?(view, "#feedback-thread-3-replies > ol > li > #feedback-4")
      assert has_element?(view, "#feedback-thread-3-replies > ol > li > #feedback-5")

      assert has_element?(
               view,
               ~s(#feedback-5-reply-to[href="#feedback-4"]),
               "回复 @#{name(ctx, :bob)} #4"
             )

      Task.async(fn -> revise(ctx, :bob, fourth, "第4（改）") end) |> Task.await()

      assert has_element?(
               view,
               ~s(#feedback-5-reply-to[href="#feedback-6"]),
               "回复 @#{name(ctx, :bob)} #6"
             )

      assert has_element?(view, "#feedback-5 [data-target-revised]", "已修订")
    end

    test "回答 replies to its question and reads as its answer", ctx do
      %{seq: q} = add_elsewhere(ctx, :agent, "question", "A 还是 B？")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      view |> element("#feedback-#{q}-answer") |> render_click()
      submit(view, %{content: "B"})

      assert has_element?(view, "#feedback-thread-#{q}-replies #feedback-2[data-kind=answer]")
      refute has_element?(view, "#feedback-2-reply-to")
      refute has_element?(view, "#task-open-question")
    end
  end

  describe "revising" do
    test "the author revises (作者修订)", ctx do
      add(ctx, :alice, "comment", "一")
      add(ctx, :bob, "comment", "二")
      add(ctx, :alice, "review", "未修复")
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)

      open_revise(view, 3)
      assert in_portal?(view, @panel, "#feedback-panel-title", "修订 BOS-1#3")
      assert {_, "未修复"} = editor_input(view)
      assert portal_attr(view, @panel, ~s(input[name="feedback[kind]"][value=review]), "checked")

      submit(view, %{kind: "review", content: "已修复"})
      assert has_element?(view, "#feedback-4", "已修复")
      assert has_element?(view, "#feedback-4 [data-supersedes]", "修订自 #3")
      assert has_element?(view, "#feedback-thread-3-history #feedback-3")
    end

    test "a user revises their agent's feedback (用户修订自己 Agent 的内容)", ctx do
      add(ctx, :alice, "comment", "一")
      add(ctx, :agent, "comment", "agent 写的")
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)

      assert has_element?(view, "#feedback-2-revise", "修订")
      open_revise(view, 2)
      submit(view, %{kind: "comment", content: "alice 改的"})

      assert has_element?(view, "#feedback-3", "alice 改的")

      assert has_element?(
               view,
               "#feedback-3 [data-actor-kind=human]",
               ctx.scopes.alice.actor.name
             )
    end

    test "someone else's feedback has no 修订 (别人的 Feedback)", ctx do
      add(ctx, :alice, "comment", "alice")
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      assert has_element?(view, "#feedback-1-copy-link")
      refute has_element?(view, "#feedback-1-revise")
      render_click(view, "open_feedback", %{"mode" => "revise", "target" => "BOS-1#1"})
      refute open?(view, @panel)
    end

    test "revised meanwhile, found when submitting (已被他人修订)", ctx do
      %{id: id} = add(ctx, :alice, "comment", "原文")
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)
      open_revise(view, 1)
      {input, _} = editor_input(view)

      # This page misses the notification, so only the domain can tell.
      topic = task_topic(ctx)

      :sys.replace_state(view.pid, fn state ->
        :ok = Phoenix.PubSub.unsubscribe(Helmsman.PubSub, topic)
        state
      end)

      revise(ctx, :alice, id, "另一个窗口")

      submit(view, %{kind: "comment", content: "这个窗口"})
      assert open?(view, @panel)

      assert in_portal?(
               view,
               @panel,
               "#feedback-panel-error",
               "这条 Feedback 已被修订为 BOS-1#2，请修订最新版本"
             )

      assert portal_attr(view, @panel, "#feedback-submit", "disabled") != nil
      assert {^input, _} = editor_input(view)
      assert length(entries()) == 2
    end

    test "revised meanwhile, found through the notification (已被他人修订)", ctx do
      %{id: id} = add(ctx, :alice, "comment", "原文")
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)
      open_revise(view, 1)
      {input, _} = editor_input(view)

      Task.async(fn -> revise(ctx, :alice, id, "另一个窗口") end) |> Task.await()

      assert in_portal?(view, @panel, "#feedback-panel-error", "已被修订为 BOS-1#2")
      assert portal_attr(view, @panel, "#feedback-submit", "disabled") != nil
      assert {^input, _} = editor_input(view)

      submit(view, %{kind: "comment", content: "这个窗口"})
      assert length(entries()) == 2
    end
  end

  describe "editing sessions" do
    test "after a successful add the next one starts empty", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)
      {first, _} = editor_input(view)
      submit(view, %{kind: "comment", content: "一"})

      open_add(view)
      {second, text} = editor_input(view)
      assert second != first
      assert String.trim(text) == ""
      assert in_portal?(view, @panel, ~s(#feedback-editor-tab-edit[aria-selected="true"]))
    end

    test "cancelling revision A then revising B shows B (从修订 A 换到修订 B)", ctx do
      add(ctx, :alice, "comment", "A 的内容")
      add(ctx, :alice, "comment", "B 的内容")
      {:ok, view, _html} = live(as(ctx, :alice), ctx.path)

      open_revise(view, 1)
      change(view, %{kind: "comment", content: "改了 A"})
      render_click(view, "close_feedback", %{})

      open_revise(view, 2)
      assert {_, "B 的内容"} = editor_input(view)
    end

    test "kind changes, notifications and errors keep the editor", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)
      {input, _} = editor_input(view)

      change(view, %{kind: "question", content: "draft"})
      assert {^input, _} = editor_input(view)

      add_elsewhere(ctx, :agent, "comment", "插进来")
      assert has_element?(view, "#feedback-1")
      assert {^input, _} = editor_input(view)

      submit(view, %{kind: "question", content: ""})
      assert in_portal?(view, @panel, "#feedback-editor-error")
      assert {^input, _} = editor_input(view)
    end

    test "a submit from an earlier editing session is ignored", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      open_add(view)
      old = session(view)
      render_click(view, "close_feedback", %{})
      open_add(view)

      render_submit(view, "submit_feedback", %{
        feedback: %{kind: "comment", content: "旧窗口"},
        editor_session: old
      })

      assert open?(view, @panel)
      assert entries() == []
    end
  end

  describe "live updates" do
    test "someone else's feedback while writing (他人写了 Feedback)", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)
      pid = view.pid
      open_add(view)
      change(view, %{kind: "comment", content: "正在写"})
      {input, _} = editor_input(view)

      add_elsewhere(ctx, :agent, "comment", "MCP 写的评论")

      assert has_element?(view, "#feedback-1", "MCP 写的评论")
      assert has_element?(view, "#feedback-1 [data-actor-kind=agent]", "keel/dev")
      assert view.pid == pid
      assert open?(view, @panel)
      assert {^input, _} = editor_input(view)
      assert portal_attr(view, @panel, "#feedback-panel-backdrop", "phx-click") == nil
    end

    test "a transition with a reason made elsewhere shows its feedback", ctx do
      {:ok, view, _html} = live(as(ctx, :bob), ctx.path)

      Task.async(fn ->
        Tasks.transition(ctx.scopes.agent, "BOS-1", "cancelled", %{
          feedback: %{kind: "comment", content: "与 BOS-9 重复"}
        })
      end)
      |> Task.await()

      assert has_element?(view, "#feedback-1[data-kind=comment]", "与 BOS-9 重复")
      assert has_element?(view, ~s(#task-history [data-reason] a[href="#feedback-1"]))
    end
  end

  describe "待回答" do
    test "list and page update when an agent asks (提问后)", ctx do
      {:ok, list, _} = live(as(ctx, :bob), "/w/#{ctx.ws.slug}/p/BOS")
      {:ok, page, _} = live(as(ctx, :bob), ctx.path)
      {list_pid, page_pid} = {list.pid, page.pid}
      refute has_element?(list, "[data-open-question]")
      refute has_element?(page, "#task-open-question")

      add_elsewhere(ctx, :agent, "comment", "先说一句")
      %{seq: q} = add_elsewhere(ctx, :agent, "question", "要不要兼容旧版？")

      assert has_element?(list, ~s(#tasks [data-open-question][aria-label="待回答"]))
      assert has_element?(page, "#task-open-question", "待回答")
      assert has_element?(page, ~s(#task-open-question[href="#feedback-#{q}"]))
      assert {list.pid, page.pid} == {list_pid, page_pid}
    end

    test "a comment does not answer (只写评论不关闭)", ctx do
      add(ctx, :agent, "question", "q1?")
      %{seq: q} = add(ctx, :agent, "question", "q2?")
      {:ok, page, _} = live(as(ctx, :bob), ctx.path)

      add_elsewhere(ctx, :bob, "comment", "我看看")
      assert has_element?(page, "#feedback-3")
      assert has_element?(page, ~s(#task-open-question[href="#feedback-#{q}"]))
    end
  end
end

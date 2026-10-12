defmodule HelmsmanWeb.TaskLive.TransitionsTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Tasks

  @panel "transition-panel"

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, ws)

    scopes =
      for role <- [:alice, :bob, :viewer], into: %{owner: owner_scope} do
        user = user_fixture()
        member_fixture(ws, user, if(role == :viewer, do: :viewer, else: :member))
        {role, workspace_scope_fixture(user, ws)}
      end

    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    task_fixture(owner_scope, "BOS")

    %{conn: conn, ws: ws, slug: ws.slug, path: "/w/#{ws.slug}/t/BOS-1", scopes: scopes}
  end

  defp as(ctx, role), do: log_in_user(ctx.conn, ctx.scopes[role].user)
  defp current(ctx), do: elem(Tasks.get(ctx.scopes.owner, "BOS-1"), 1)

  defp move(ctx, role, to, opts \\ %{}),
    do: {:ok, _} = Tasks.transition(ctx.scopes[role], "BOS-1", to, opts)

  # IDs of the transition buttons in the header, in order, with their variant.
  defp buttons(view) do
    view
    |> element("header")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^=transition-]:not([id^=transition-more])")
    |> Enum.map(fn node ->
      [id] = LazyHTML.attribute(node, "id")
      [class] = LazyHTML.attribute(node, "class")
      {String.replace_prefix(id, "transition-", ""), class =~ "btn-primary"}
    end)
  end

  defp open_panel(view, to), do: view |> element("#transition-#{to}") |> render_click()

  # The reason editor's session goes with the form, as in the browser.
  defp submit(view, params) do
    session = portal_attr(view, @panel, "input[name=editor_session]", "value")
    form = %{transition: params}

    render_submit(
      view,
      "submit_transition",
      if(session, do: Map.put(form, :editor_session, session), else: form)
    )
  end

  defp last_entry(ctx),
    do: ctx |> current() |> Tasks.detail() |> Map.fetch!(:history) |> List.last()

  describe "buttons" do
    test "a new task", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      assert buttons(view) == [{"rejected", false}, {"cancelled", false}, {"in_progress", true}]
      assert has_element?(view, "#transition-in_progress", "开始")
      assert has_element?(view, "#transition-rejected", "拒绝")
      assert has_element?(view, "#transition-cancelled", "撤销")

      more = view |> element("#transition-more-popover") |> render()
      assert more =~ "拒绝"
      assert more =~ "撤销"
      refute more =~ "开始"
      assert has_element?(view, ".sm\\:hidden #transition-more-trigger")
      assert has_element?(view, "header .max-sm\\:hidden #transition-rejected")
    end

    test "a done task", ctx do
      move(ctx, :alice, "in_progress")
      move(ctx, :alice, "done")
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)
      assert buttons(view) == [{"in_progress", false}, {"verified", true}]
      assert has_element?(view, "#transition-in_progress", "打回")
      assert has_element?(view, "#transition-verified", "验收")
    end

    test "a verified task", ctx do
      move(ctx, :alice, "in_progress")
      move(ctx, :alice, "done")
      move(ctx, :bob, "verified")
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)
      assert buttons(view) == [{"in_progress", false}]
      assert has_element?(view, "#transition-in_progress", "重开")
    end

    test "viewers see the status but no buttons", ctx do
      {:ok, view, _} = live(as(ctx, :viewer), ctx.path)
      assert has_element?(view, "#task-status", "新建")
      assert buttons(view) == []
      refute has_element?(view, "#transition-more")
    end

    test "开始 runs at once and claims the task", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      view |> element("#transition-in_progress") |> render_click()

      refute open?(view, @panel)
      assert has_element?(view, "#task-status", "进行中")
      assert has_element?(view, "#task-assignee", ctx.scopes.alice.actor.name)
      assert has_element?(view, "#task-history > li:last-child", "进行中")
      assert length(current(ctx) |> Tasks.detail() |> Map.fetch!(:history)) == 2
    end

    test "a cancelled task can only be restored", ctx do
      move(ctx, :alice, "cancelled", %{comment: "dup"})
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      assert buttons(view) == [{"new", true}]
      view |> element("#transition-new", "恢复") |> render_click()
      assert has_element?(view, "#task-status", "新建")
    end
  end

  describe "evidence panel" do
    setup ctx do
      move(ctx, :alice, "in_progress")
      :ok
    end

    test "completing with commits and a passing test", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      view |> element("#transition-done") |> render_click()
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#transition-panel-title", "完成 BOS-1")

      submit(view, %{
        commits: "ABC1234 def5678",
        result: "passed",
        command: "mix test",
        summary: "",
        comment: ""
      })

      refute open?(view, @panel)
      assert has_element?(view, "#task-status", "待验收")
      entry = "#task-history > li:last-child"
      assert has_element?(view, entry <> " code", "abc1234")
      assert has_element?(view, entry <> " code", "def5678")
      assert has_element?(view, entry <> " [data-tests] code", "mix test")
      assert has_element?(view, "#task-commits", "abc1234")
    end

    test "invalid commits are reported on the field", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      open_panel(view, "done")
      submit(view, %{commits: "xyz", result: "none", comment: "keep"})

      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#transition-commits-error", "不是有效的提交 hash：xyz")
      assert portal_text(view, @panel, "#transition-comment") =~ "keep"
      assert current(ctx).status == :in_progress
    end

    test "a test result needs a command", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      open_panel(view, "done")
      render_change(view, "transition_change", %{transition: %{result: "failed"}})
      assert in_portal?(view, @panel, "#transition-command")

      submit(view, %{commits: "", result: "failed", command: " ", comment: ""})
      assert in_portal?(view, @panel, "#transition-command-error", "不能为空")
      assert current(ctx).status == :in_progress
    end
  end

  describe "self verification" do
    test "the assignee is told and rejected without tests", ctx do
      move(ctx, :alice, "in_progress")
      move(ctx, :alice, "done")
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)

      open_panel(view, "verified")
      assert in_portal?(view, @panel, "#transition-panel-title", "验收 BOS-1")

      assert in_portal?(
               view,
               @panel,
               "#self-verify-hint",
               "你是执行方：验收需要通过的测试结果。最近一次完成没有附带通过的测试，请在下方填写"
             )

      submit(view, %{commits: "", result: "none", comment: "looks good"})
      assert in_portal?(view, @panel, "#transition-panel-error", "你是执行方，验收需要通过的测试结果")
      assert portal_text(view, @panel, "#transition-comment") =~ "looks good"
      assert current(ctx).status == :done
    end

    test "a passing test of the last completion is shown", ctx do
      move(ctx, :alice, "in_progress")
      move(ctx, :alice, "done", %{tests: %{command: "mix test", passed: true, summary: ""}})
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)

      open_panel(view, "verified")
      assert in_portal?(view, @panel, "#self-verify-hint code", "mix test")
      submit(view, %{commits: "", result: "none", comment: ""})
      refute open?(view, @panel)
      assert current(ctx).status == :verified
    end

    test "the owner of the assigned agent verifies without tests", ctx do
      alice = ctx.scopes.alice
      feature = %{alice | actor: agent_fixture(ctx.ws, alice.user, "alice/feature-x")}
      {:ok, _} = Tasks.transition(feature, "BOS-1", "in_progress", %{})
      {:ok, _} = Tasks.transition(feature, "BOS-1", "done", %{})
      assert current(ctx).assignee.name == "alice/feature-x"

      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      open_panel(view, "verified")
      refute in_portal?(view, @panel, "#self-verify-hint")

      submit(view, %{commits: "", result: "none", comment: ""})
      assert current(ctx).status == :verified
    end
  end

  describe "reason panels" do
    defp reason_case(ctx, setup_moves, to, label, status, kind \\ {"review", "评审"}) do
      Enum.each(setup_moves, fn {role, s, opts} -> move(ctx, role, s, opts) end)
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)

      open_panel(view, to)
      assert in_portal?(view, @panel, "#transition-panel-title", "#{label} BOS-1")
      assert in_portal?(view, @panel, "#transition-help")
      assert in_portal?(view, @panel, "#transition-editor [data-hm-editor], #transition-editor")

      assert in_portal?(
               view,
               @panel,
               ~s(textarea[name="transition[comment]"][data-submit=mod-enter-form])
             )

      submit(view, %{comment: "原因：#{label}"})
      refute open?(view, @panel)
      assert has_element?(view, "#task-status", status)

      # The reason is a feedback record of the right kind, referred to by the entry.
      %{feedback: id} = entry = last_entry(ctx)
      assert id =~ ~r/^BOS-1#\d+$/
      seq = id |> String.split("#") |> List.last()
      assert entry.comment in [nil, ""]

      {kind, kind_label} = kind
      card = "#feedback-#{seq}"
      assert has_element?(view, ~s(#{card}[data-kind="#{kind}"]), "原因：#{label}")
      assert has_element?(view, "#{card} [data-kind-badge]", kind_label)

      link = "#task-history > li:last-child [data-reason] a[href='#feedback-#{seq}']"
      assert has_element?(view, link, id)
      assert has_element?(view, "#task-history > li:last-child [data-reason]", "原因：")
      refute has_element?(view, "#task-history > li:last-child [data-comment]")
    end

    @started {:alice, "in_progress", %{}}
    @done {:alice, "done", %{}}

    test "打回 keeps the assignee", ctx do
      reason_case(ctx, [@started, @done], "in_progress", "打回", "进行中")
      assert current(ctx).assignee.name == ctx.scopes.alice.actor.name
    end

    test "重开", ctx do
      reason_case(ctx, [@started, @done, {:bob, "verified", %{}}], "in_progress", "重开", "进行中")
    end

    test("拒绝", ctx, do: reason_case(ctx, [], "rejected", "拒绝", "已拒绝"))

    test "重新提交", ctx do
      reason_case(ctx, [{:alice, "rejected", %{comment: "no"}}], "new", "重新提交", "新建")
    end

    test "撤销的原因 is a comment", ctx do
      reason_case(ctx, [], "cancelled", "撤销", "已撤销", {"comment", "评论"})
    end

    test "a reason is required", ctx do
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)
      open_panel(view, "cancelled")
      submit(view, %{comment: "  "})
      assert in_portal?(view, @panel, "#transition-editor-error", "请填写原因")
      assert current(ctx).status == :new
    end

    test "a reason over 64 KB is reported under the field and the input stays", ctx do
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)
      open_panel(view, "cancelled")
      assert in_portal?(view, @panel, "#transition-editor-input-1")

      submit(view, %{comment: String.duplicate("长", 22_000)})
      assert in_portal?(view, @panel, "#transition-editor-error", "不能超过 64 KB")
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#transition-editor-input-1")
      assert current(ctx).status == :new
    end

    test "a submit from an earlier reason editor is ignored", ctx do
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)
      open_panel(view, "cancelled")

      render_submit(view, "submit_transition", %{
        transition: %{comment: "旧的"},
        editor_session: "0"
      })

      assert open?(view, @panel)
      assert current(ctx).status == :new
    end

    test "each opened panel starts an empty reason editor", ctx do
      move(ctx, :alice, "in_progress")
      move(ctx, :alice, "done")
      {:ok, view, _} = live(as(ctx, :bob), ctx.path)

      open_panel(view, "in_progress")
      assert in_portal?(view, @panel, "#transition-editor-input-1")
      render_click(view, "close_transition", %{})

      open_panel(view, "verified")
      refute in_portal?(view, @panel, "[id^=transition-editor-input]")
      render_click(view, "close_transition", %{})

      open_panel(view, "in_progress")
      refute in_portal?(view, @panel, "#transition-editor-input-1")
      assert in_portal?(view, @panel, "#transition-editor-input-3")
      assert portal_text(view, @panel, "#transition-editor-input-3") |> String.trim() == ""
    end
  end

  describe "failures and concurrency" do
    test "the task moved on while the panel was open", ctx do
      move(ctx, :alice, "in_progress")
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      open_panel(view, "done")

      render_change(view, "transition_change", %{
        transition: %{commits: "abc1234", result: "none", comment: "mine"}
      })

      move(ctx, :bob, "cancelled", %{comment: "dup"})

      assert in_portal?(view, @panel, "#transition-panel-error", "任务状态已变为已撤销，无法完成")
      assert portal_attr(view, @panel, "#transition-submit", "disabled") != nil

      submit(view, %{commits: "abc1234", result: "none", comment: "mine"})
      assert open?(view, @panel)
      assert portal_text(view, @panel, "#transition-comment") =~ "mine"
      assert current(ctx).status == :cancelled

      render_click(view, "close_transition", %{})
      assert has_element?(view, "#task-status", "已撤销")
      assert buttons(view) == [{"new", true}]
    end

    test "a direct transition that is no longer allowed", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      move(ctx, :bob, "in_progress")
      render_click(view, "transition", %{"to" => "in_progress", "from" => "new"})
      assert render(view) =~ "任务状态已变为进行中，无法开始"
    end

    test "viewers are refused", ctx do
      {:ok, view, _} = live(as(ctx, :viewer), ctx.path)
      render_click(view, "transition", %{"to" => "in_progress", "from" => "new"})
      assert render(view) =~ "没有权限执行此操作"
      assert current(ctx).status == :new
    end

    # code-review-1 R3: the target of an outdated button may still be allowed, but it
    # would be another action (打回 / 重开 / 重新提交) without its reason.
    defp history_size(ctx),
      do: ctx |> current() |> Tasks.detail() |> Map.fetch!(:history) |> length()

    defp stale_direct_click(ctx, moves, button_to, status, message) do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      # The page still shows the buttons of the status it was rendered with.
      click = view |> element("#transition-#{button_to}") |> render() |> phx_click_value()

      Enum.each(moves, fn {role, to, opts} -> move(ctx, role, to, opts) end)
      before = history_size(ctx)

      render_click(view, "transition", click)

      assert current(ctx).status == status
      assert history_size(ctx) == before
      assert render(view) =~ message
    end

    defp phx_click_value(html) do
      [js] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> LazyHTML.attribute("phx-click")

      [["push", %{"value" => value}]] = Jason.decode!(js)
      value
    end

    test "an old 开始 does not reopen a done task", ctx do
      stale_direct_click(
        ctx,
        [{:bob, "in_progress", %{}}, {:bob, "done", %{}}],
        "in_progress",
        :done,
        "任务状态已变为待验收，无法开始"
      )
    end

    test "an old 开始 does not reopen a verified task", ctx do
      stale_direct_click(
        ctx,
        [{:bob, "in_progress", %{}}, {:bob, "done", %{}}, {:alice, "verified", %{}}],
        "in_progress",
        :verified,
        "任务状态已变为已验收，无法开始"
      )
    end

    test "an old 恢复 does not resubmit a rejected task", ctx do
      move(ctx, :bob, "cancelled", %{comment: "dup"})

      stale_direct_click(
        ctx,
        [{:bob, "new", %{}}, {:bob, "rejected", %{comment: "no"}}],
        "new",
        :rejected,
        "任务状态已变为已拒绝，无法恢复"
      )
    end

    test "a click without its source status is refused", ctx do
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)
      render_click(view, "transition", %{"to" => "in_progress"})
      assert current(ctx).status == :new
    end

    test "an agent's transition shows up live", ctx do
      owner = ctx.scopes.owner
      keel = %{owner | actor: agent_fixture(ctx.ws, owner.user, "keel/dev")}
      {:ok, view, _} = live(as(ctx, :alice), ctx.path)

      {:ok, _} = Tasks.transition(keel, "BOS-1", "in_progress", %{})

      assert has_element?(view, "#task-status", "进行中")
      assert buttons(view) == [{"rejected", false}, {"cancelled", false}, {"done", true}]

      assert has_element?(
               view,
               "#task-history > li:last-child [data-actor-kind=agent]",
               "keel/dev"
             )
    end
  end
end

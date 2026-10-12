defmodule HelmsmanWeb.TaskLive.ShowTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks
  alias HelmsmanWeb.TaskLive.Show

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, ws)

    scopes =
      for role <- [:member, :bob, :viewer], into: %{owner: owner_scope} do
        user = user_fixture()
        member_fixture(ws, user, if(role == :viewer, do: :viewer, else: :member))
        {role, workspace_scope_fixture(user, ws)}
      end

    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    task_fixture(owner_scope, "BOS")
    task_fixture(owner_scope, "BOS")

    task =
      task_fixture(owner_scope, "BOS", %{
        title: "Fix login",
        description: "line 1\nline 2 <script>alert(1)</script>",
        labels: ["api"]
      })

    %{
      conn: conn,
      ws: ws,
      slug: ws.slug,
      path: "/w/#{ws.slug}/t/BOS-3",
      scopes: scopes,
      task: task,
      owner_user: owner
    }
  end

  defp as(ctx, role), do: log_in_user(ctx.conn, ctx.scopes[role].user)
  defp current(ctx), do: elem(Tasks.get(ctx.scopes.owner, "BOS-3"), 1)

  describe "task page" do
    test "renders header, content, properties and history", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      assert has_element?(view, ~s(header nav a[href="/w/#{ctx.slug}/p/BOS"]), "BOS")
      assert has_element?(view, "header h1", "BOS-3")
      assert has_element?(view, "#task-title", "Fix login")
      assert has_element?(view, "#task-description-text .hm-prose p", "line 1")
      assert has_element?(view, "#task-properties", "优先级")
      assert has_element?(view, "#task-labels [data-label=api]")
      assert has_element?(view, "#task-history > li", "创建了任务")
      assert page_title(view) =~ ~r/^BOS-3 Fix login/
      assert render(view) =~ "lg:grid-cols-[minmax(0,1fr)_320px]"
    end

    test "raw HTML in the description is escaped", ctx do
      {:ok, _view, html} = live(as(ctx, :member), ctx.path)
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "empty descriptions", ctx do
      {:ok, _} = Tasks.update(ctx.scopes.owner, "BOS-3", %{description: ""})

      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      assert has_element?(view, "#task-description-placeholder", "添加描述…")

      {:ok, view, _html} = live(as(ctx, :viewer), ctx.path)
      refute has_element?(view, "#task-description-placeholder")
      assert has_element?(view, "#task-description", "没有描述")
    end

    test "lower-case IDs go to the canonical address", ctx do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(as(ctx, :member), "/w/#{ctx.slug}/t/bos-3?x=1")

      assert to == ctx.path <> "?x=1"
    end

    test "unknown tasks and other workspaces' tasks are 404", ctx do
      other_owner = user_fixture()
      other = workspace_fixture(other_owner)
      other_scope = workspace_scope_fixture(other_owner, other)
      project_fixture(other_scope, key: "OTH", name: "Other")
      task_fixture(other_scope, "OTH")

      conn = as(ctx, :member)
      assert_raise HelmsmanWeb.NotFoundError, fn -> live(conn, "/w/#{ctx.slug}/t/OTH-1") end
      assert_raise HelmsmanWeb.NotFoundError, fn -> live(conn, "/w/#{ctx.slug}/t/BOS-99") end
    end

    test "visiting records the task for 最近访问", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      assert_push_event(view, "hm:visit-task", %{ident: "BOS-3"})
    end
  end

  describe "title and description" do
    test "editing the title", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      view |> element("#task-title-edit") |> render_click()
      assert has_element?(view, ~s(#task-title-input[phx-hook=Editor][data-submit=enter]))

      render_hook(view, "save_field", %{"field" => "title", "value" => "修复登录跳转"})
      refute has_element?(view, "#task-title-input")
      assert has_element?(view, "#task-title", "修复登录跳转")
      assert page_title(view) =~ "BOS-3 修复登录跳转"
    end

    test "a too long title keeps the editor and the input", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      long = String.duplicate("a", 201)

      view |> element("#task-title-edit") |> render_click()
      render_hook(view, "save_field", %{"field" => "title", "value" => long})

      assert has_element?(view, ~s(#task-title-input[value="#{long}"]))
      assert has_element?(view, "#task-title-error", "200")
      assert current(ctx).title == "Fix login"
    end

    test "cancel restores the value", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-title-edit") |> render_click()
      render_hook(view, "cancel_field", %{"field" => "title"})
      refute has_element?(view, "#task-title-input")
      assert has_element?(view, "#task-title", "Fix login")
    end

    test "the save button and Ctrl/⌘+Enter take the same path", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      view |> element("#task-description-edit") |> render_click()

      assert has_element?(
               view,
               ~s(#task-description-form #description-editor-input-1[name=value][phx-hook=Editor][data-submit=mod-enter][data-field=description])
             )

      view
      |> form("#task-description-form", %{value: "from the button"})
      |> render_submit()

      assert current(ctx).description == "from the button"
      assert has_element?(view, "#task-description-text", "from the button")

      view |> element("#task-description-edit") |> render_click()

      render_hook(view, "save_field", %{
        "field" => "description",
        "value" => "from the keys",
        "session" => 2
      })

      assert current(ctx).description == "from the keys"
    end

    test "Markdown description (Markdown 描述)", ctx do
      {:ok, _} =
        Tasks.update(ctx.scopes.owner, "BOS-3", %{description: "## 复现步骤\n\n1. 打开\n2. 登录"})

      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      assert has_element?(view, "#task-description-text .hm-prose h2", "复现步骤")
      assert has_element?(view, "#task-description-text .hm-prose ol > li", "登录")
      refute has_element?(view, "#task-description-text", "## 复现步骤")
    end

    test "previewing the description (预览描述)", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()
      editor = with_target(view, "#description-editor")

      render_hook(editor, "set_mode", %{
        "mode" => "preview",
        "value" => "- [ ] 写测试",
        "session" => 1
      })

      assert has_element?(view, "#description-editor-preview input[type=checkbox]")
      assert has_element?(view, "#description-editor-source.hidden #description-editor-input-1")

      render_hook(editor, "set_mode", %{"mode" => "edit", "value" => "- [ ] 写测试", "session" => 1})
      view |> form("#task-description-form", %{value: "- [ ] 写测试"}) |> render_submit()

      assert has_element?(view, "#task-description-text .hm-prose li input[type=checkbox]")
    end

    test "saving from the preview saves the textarea", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()

      render_hook(with_target(view, "#description-editor"), "set_mode", %{
        "mode" => "preview",
        "value" => "**预览中**",
        "session" => 1
      })

      view |> form("#task-description-form", %{value: "**预览中**"}) |> render_submit()
      assert current(ctx).description == "**预览中**"
      assert has_element?(view, "#task-description-text strong", "预览中")
    end

    test "each edit starts a new editor with the description of that moment", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()
      view |> element("#task-description-cancel") |> render_click()

      {:ok, _} = Tasks.update(ctx.scopes.bob, "BOS-3", %{description: "bob wrote this"})

      view |> element("#task-description-edit") |> render_click()
      refute has_element?(view, "#description-editor-input-1")
      assert has_element?(view, "#description-editor-input-2", "bob wrote this")
      assert has_element?(view, ~s(#description-editor-tab-edit[aria-selected="true"]))

      view |> form("#task-description-form", %{value: "saved"}) |> render_submit()
      view |> element("#task-description-edit") |> render_click()
      assert has_element?(view, "#description-editor-input-3", "saved")
    end

    test "events of an earlier description session are ignored", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()
      view |> element("#task-description-cancel") |> render_click()
      view |> element("#task-description-edit") |> render_click()

      render_hook(view, "save_field", %{
        "field" => "description",
        "value" => "old tab",
        "session" => 1
      })

      assert current(ctx).description =~ "line 1"
      assert has_element?(view, "#description-editor-input-2")

      render_hook(view, "cancel_field", %{"field" => "description", "session" => 1})
      assert has_element?(view, "#description-editor-input-2")
    end

    test "viewers only read", ctx do
      {:ok, view, _html} = live(as(ctx, :viewer), ctx.path)

      refute has_element?(view, "#task-title-edit")
      refute has_element?(view, "#task-description-edit")
      refute has_element?(view, "#priority-menu")
      refute has_element?(view, "#assignee-menu")
      refute has_element?(view, "#labels-trigger")

      render_hook(view, "edit_field", %{"field" => "title"})
      refute has_element?(view, "#task-title-input")
    end

    test "a stale save keeps the draft and reloads the task", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()

      task = current(ctx)
      {:ok, _} = Tasks.update(ctx.scopes.bob, "BOS-3", %{description: "bob's"}, task.lock_version)

      save = %{"field" => "description", "value" => "alice's", "session" => 1}
      render_hook(view, "save_field", save)
      assert render(view) =~ "此任务已被其他人修改，已加载最新内容"
      # Same editing session: the textarea (the browser's draft) is left alone.
      assert has_element?(view, "#description-editor-input-1")
      assert current(ctx).description == "bob's"

      render_hook(view, "save_field", save)
      assert current(ctx).description == "alice's"
      assert has_element?(view, "#task-description-text", "alice's")
    end
  end

  describe "property menus" do
    test "assigning an agent", ctx do
      agent_fixture(ctx.ws, ctx.owner_user, "keel/dev")
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      assert has_element?(view, ~s(#priority-medium[aria-checked="true"]))
      assert has_element?(view, "#assignee-none")

      view
      |> element("#" <> Show.assignee_item_id("keel/dev"))
      |> render_click()

      assert has_element?(view, "#task-assignee [data-actor-kind=agent]", "keel/dev")
      assert current(ctx).assignee.name == "keel/dev"

      view |> element("#assignee-none") |> render_click()
      assert has_element?(view, "#task-assignee", "—")
      assert current(ctx).assignee == nil
    end

    test "similar identity names get distinct menu items (code-review-1 R1)", ctx do
      names = ["keel/dev", "keel-dev", "keel.dev"]
      for name <- names, do: agent_fixture(ctx.ws, ctx.owner_user, name)

      # A duplicate id would make LiveViewTest raise here.
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      for name <- names do
        view |> element("#" <> Show.assignee_item_id(name)) |> render_click()
        assert current(ctx).assignee.name == name
        assert has_element?(view, "#task-assignee", name)
      end
    end

    test "priority", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#priority-high") |> render_click()
      assert current(ctx).priority == :high
      assert has_element?(view, ~s(#priority-high[aria-checked="true"]))
    end

    test "adding and removing labels", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)

      view |> element("#labels-trigger") |> render_click()
      view |> form("#labels-new-form", %{new_label: " API "}) |> render_submit()
      view |> form("#labels-new-form", %{new_label: " Backend "}) |> render_submit()
      view |> element("#labels-done") |> render_click()
      refute has_element?(view, "#labels-popover")
      assert current(ctx).labels == ["api", "backend"]

      view |> element("#labels-trigger") |> render_click()
      view |> element(~s(#labels-popover input[data-label="api"])) |> render_click()
      render_click(view, "save_labels", %{})
      assert current(ctx).labels == ["backend"]
    end

    test "a menu choice made on an outdated page is rejected", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      old = current(ctx).lock_version
      {:ok, _} = Tasks.update(ctx.scopes.bob, "BOS-3", %{title: "Bob's title"}, old)

      render_click(view, "set_field", %{
        "field" => "priority",
        "value" => "high",
        "version" => old
      })

      assert render(view) =~ "此任务已被其他人修改，已加载最新内容"
      assert has_element?(view, "#task-title", "Bob's title")
      assert current(ctx).priority == :medium
    end
  end

  describe "live updates" do
    test "someone else's assignment shows up in place", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      pid = view.pid

      {:ok, _} = Tasks.update(ctx.scopes.owner, "BOS-3", %{assignee: ctx.scopes.bob.actor.name})

      assert has_element?(view, "#task-assignee", ctx.scopes.bob.actor.name)
      assert view.pid == pid
    end

    test "an update while editing marks the editor and keeps the draft", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      view |> element("#task-description-edit") |> render_click()

      render_change(view, "draft_field", %{
        "field" => "description",
        "value" => "my draft",
        "editor_session" => "1"
      })

      {:ok, _} = Tasks.update(ctx.scopes.bob, "BOS-3", %{description: "bob's version"})

      assert has_element?(view, "#description-editor-input-1")
      assert has_element?(view, "#task-description [data-updated]", "有更新")

      view |> element("#task-description-cancel") |> render_click()
      assert has_element?(view, "#task-description-text", "bob's version")
    end

    test "the page title follows title changes", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.path)
      {:ok, _} = Tasks.update(ctx.scopes.bob, "BOS-3", %{title: "New title"})
      _ = render(view)
      assert page_title(view) =~ "BOS-3 New title"
    end
  end
end

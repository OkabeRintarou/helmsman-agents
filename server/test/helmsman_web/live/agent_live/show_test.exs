defmodule HelmsmanWeb.AgentLive.ShowTest do
  @moduledoc "Spec web-agents Agent 详情页、停用启用与归档、Agent 页实时刷新 (design D4)."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Repo}

  setup %{conn: conn} do
    _admin = user_fixture()
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    users = %{alice: alice}

    users =
      for {role, name} <- [admin: "adam", member: "bob", viewer: "vic"], into: users do
        user = user_fixture(%{display_name: name})
        member_fixture(ws, user, role)
        {String.to_atom(name), user}
      end

    alice_scope = workspace_scope_fixture(alice, ws)

    managed_agent_fixture(alice_scope, %{
      name: "keel/dev",
      instructions: "## 规则\n\n先写测试",
      env: %{"API_KEY" => "s3cret"},
      extra_mcp_servers: %{
        "gh" => %{"command" => "npx", "auth" => "mcp-secret-cmd", "env" => %{"T" => "mcpval"}}
      }
    })

    %{
      conn: conn,
      ws: ws,
      users: users,
      alice_scope: alice_scope,
      path: "/w/#{ws.slug}/agents/keel/dev"
    }
  end

  defp open(ctx, who, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path || ctx.path)

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  describe "display" do
    test "a managed agent: breadcrumb, tabs and properties", ctx do
      {:ok, view, _html} = open(ctx, :bob)

      assert page_title(view) == "keel/dev · Acme"

      assert has_element?(
               view,
               ~s(nav[aria-label="面包屑"] a[href="/w/#{ctx.ws.slug}/agents"]),
               "Agents"
             )

      assert has_element?(view, "h1", "keel/dev")
      assert has_element?(view, ~s(#agent-status[data-agent-status="idle"]))
      assert has_element?(view, ~s(nav a[aria-current="page"]), "运行")

      assert has_element?(view, "#agent-properties [data-provider-row]", "Claude Code")
      assert has_element?(view, "#agent-properties [data-runtime-row]", "test-machine")
      assert has_element?(view, "#agent-properties [data-access]", "仅所属用户")
      assert has_element?(view, "#agent-properties [data-model]", "CLI 缺省")
      assert has_element?(view, "#agent-properties [data-max-concurrency]", "2")
    end

    test "only the names of variables and MCP servers", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      assert has_element?(view, "#agent-properties [data-env-names]", "API_KEY")
      assert has_element?(view, "#agent-properties [data-mcp-names]", "gh")

      html = render(view)
      refute html =~ "s3cret"
      refute html =~ "mcp-secret-cmd"
      refute html =~ "mcpval"

      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=edit")
      assert open?(view, "agent-panel")
      panel = view |> portal("agent-panel") |> LazyHTML.to_html()
      refute panel =~ "s3cret"
      refute panel =~ "mcp-secret-cmd"
    end

    test "a name in another case goes to the canonical address", ctx do
      assert {:error, {:live_redirect, %{to: to}}} =
               open(ctx, :bob, "/w/#{ctx.ws.slug}/agents/Keel/Dev")

      assert to == ctx.path
    end

    test "an unknown agent is a 404", ctx do
      assert_raise HelmsmanWeb.NotFoundError, fn ->
        open(ctx, :bob, "/w/#{ctx.ws.slug}/agents/nobody")
      end
    end

    test "an agent of another workspace is a 404", ctx do
      other = workspace_fixture(ctx.users.alice, %{name: "Other"})
      managed_agent_fixture(workspace_scope_fixture(ctx.users.alice, other), %{name: "keel/x"})

      assert_raise HelmsmanWeb.NotFoundError, fn ->
        open(ctx, :alice, "/w/#{ctx.ws.slug}/agents/keel/x")
      end
    end

    test "an external agent shows only its card", ctx do
      Repo.insert!(%Actor{
        workspace_id: ctx.ws.id,
        kind: :agent,
        name: "bob/session-1",
        owner_id: ctx.users.bob.id
      })

      {:ok, view, _html} = open(ctx, :bob, "/w/#{ctx.ws.slug}/agents/bob/session-1")

      assert has_element?(view, "#agent-external", "Helmsman 不派发运行")
      assert has_element?(view, "#agent-external", "外接")
      refute has_element?(view, "#agent-layout")
      refute has_element?(view, "#agent-edit")
      refute has_element?(view, "#agent-more-trigger")
    end

    test "the instructions tab renders Markdown, or 没有指令", ctx do
      {:ok, view, _html} = open(ctx, :bob, ctx.path <> "?tab=instructions")
      assert has_element?(view, "#agent-instructions h2", "规则")

      managed_agent_fixture(ctx.alice_scope, %{name: "keel/bare"})
      {:ok, view, _html} = open(ctx, :bob, "/w/#{ctx.ws.slug}/agents/keel/bare?tab=instructions")
      assert has_element?(view, "#agent-instructions", "没有指令")
    end
  end

  describe "disable, enable and archive" do
    test "disabling after confirming, then 启用", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      view |> element("#agent-disable") |> render_click()

      assert in_portal?(
               view,
               "agent-confirm",
               "#agent-confirm-description",
               "停用后 keel/dev 不能再被触发，正在进行的运行会被停止，排队中的运行会被取消"
             )

      render_click(view, "disable", %{})
      assert has_element?(view, ~s(#agent-status[data-agent-status="disabled"]), "已停用")
      assert has_element?(view, "#agent-enable", "启用")
      refute has_element?(view, "#agent-disable")

      view |> element("#agent-enable") |> render_click()
      assert has_element?(view, ~s(#agent-status[data-agent-status="idle"]))
    end

    test "an admin cannot enable, but can archive", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
      {:ok, view, _html} = open(ctx, :adam)

      refute has_element?(view, "#agent-enable")
      assert has_element?(view, "#agent-archive")
      assert has_element?(view, "#agent-edit")
    end

    test "archiving leaves the agent read-only", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      view |> element("#agent-archive") |> render_click()
      assert in_portal?(view, "agent-confirm", "#agent-confirm-description", "不可撤销")
      render_click(view, "archive", %{})

      assert has_element?(view, ~s(#agent-status[data-agent-status="archived"]), "已归档")
      refute has_element?(view, "#agent-edit")
      refute has_element?(view, "#agent-enable")
      refute has_element?(view, "#agent-more-trigger")
    end

    test "viewers and unrelated members get no actions; a forged event is refused", ctx do
      for who <- [:vic, :bob] do
        {:ok, view, _html} = open(ctx, who)
        refute has_element?(view, "#agent-edit")
        refute has_element?(view, "#agent-enable")
        refute has_element?(view, "#agent-more-trigger")
      end

      {:ok, view, _html} = open(ctx, :bob)
      assert render_click(view, "disable", %{}) =~ "没有权限执行此操作"
      assert {:ok, %{disabled: false}} = Agents.get(ctx.alice_scope, "keel/dev")
    end
  end

  describe "live updates" do
    test "a disable in another window", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      pid = view.pid
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")

      eventually(fn -> has_element?(view, ~s(#agent-status[data-agent-status="disabled"])) end)
      assert view.pid == pid
    end
  end

  describe "manual runs (web-agents 手动运行)" do
    setup ctx do
      project =
        Helmsman.ProjectsFixtures.project_fixture(ctx.alice_scope, key: "BOS", name: "Bosun")

      task = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, project.key)
      %{task: task}
    end

    defp submit_run(view, task, instructions),
      do:
        render_submit(view, "run_submit", %{
          "run" => %{"task" => task, "instructions" => instructions}
        })

    test "with instructions: queued, a link to the run, the card in 运行", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=run")
      assert open?(view, "run-panel")

      html = submit_run(view, ctx.task.ident, "先补测试")
      assert html =~ "已派发给 keel/dev"
      assert html =~ ~s(data-run-link)
      refute open?(view, "run-panel")

      assert has_element?(view, ~s(#agent-runs-open [data-run-status="queued"]))
      assert has_element?(view, "#agent-runs-open [data-run-triggers]", "手动运行")
      assert has_element?(view, "#agent-runs-open [data-run-triggers-tip]", "先补测试")
    end

    # An enabled 运行 button is a live patch link, not inert (`disabled_reason` nil, not
    # false: code-reply-7).
    test "the enabled 运行 button opens the panel", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path)
      assert has_element?(view, ~s(a#agent-run[data-phx-link="patch"][href$="?panel=run"]))
      refute has_element?(view, "#agent-run[data-hm-disabled]")

      view |> element("#agent-run") |> render_click()
      assert open?(view, "run-panel")
    end

    test "a second trigger merges", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=run")
      submit_run(view, ctx.task.ident, "一")
      render_patch(view, ctx.path <> "?panel=run")
      assert submit_run(view, ctx.task.ident, "二") =~ "已并入 keel/dev 排队中的运行"
      assert has_element?(view, "#agent-runs-open [data-run-triggers]", "等 2 条触发")
    end

    test "neither task nor instructions", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=run")
      submit_run(view, "", "")
      assert open?(view, "run-panel")
      assert in_portal?(view, "run-panel", "#run-form", "不指定任务时必须填写说明")
    end

    test "an unknown or closed task, instructions too long", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=run")

      submit_run(view, "BOS-99", "")
      assert in_portal?(view, "run-panel", "#run-form", "任务不存在")
      assert portal_attr(view, "run-panel", "#run-task", "value") == "BOS-99"

      {:ok, _} =
        Helmsman.Tasks.transition(ctx.alice_scope, ctx.task.ident, "cancelled", %{reason: "不做了"})

      submit_run(view, ctx.task.ident, "")
      assert in_portal?(view, "run-panel", "#run-form", "任务已验收或撤销")

      submit_run(view, "", String.duplicate("x", 8193))
      assert in_portal?(view, "run-panel", "#run-form", "说明不能超过 8 KB")
    end

    test "a refusal after opening is a warning and closes the panel", ctx do
      {:ok, agent} = Agents.get(ctx.alice_scope, "keel/dev")
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=run")
      {:ok, _} = Helmsman.Runtimes.disable(ctx.alice_scope, agent.runtime.id)

      assert submit_run(view, "", "做点事") =~ "没有启动 keel/dev：运行时已禁用"
      refute open?(view, "run-panel")
    end

    test "a member who cannot trigger sees a disabled button; a viewer sees none", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      assert has_element?(view, "#agent-run[aria-disabled]")
      assert has_element?(view, "#agent-run-reason", "你无权触发 keel/dev")

      {:ok, view, _html} = open(ctx, :bob, ctx.path <> "?panel=run")
      refute open?(view, "run-panel")

      {:ok, view, _html} = open(ctx, :vic)
      refute has_element?(view, "#agent-run")
    end
  end
end

defmodule HelmsmanWeb.AgentLive.McpEditorTest do
  use HelmsmanWeb.ConnCase, async: true
  import HelmsmanWeb.PortalHelpers
  import Phoenix.LiveViewTest
  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures
  alias Helmsman.{Agents, McpServers, Repo}
  alias HelmsmanWeb.AgentForm

  setup %{conn: conn} do
    user = user_fixture()
    ws = workspace_fixture(user)
    scope = workspace_scope_fixture(user, ws)

    agent =
      managed_agent_fixture(scope, %{
        name: "mcp-dev",
        extra_mcp_servers: %{
          "docs" => %{
            "type" => "http",
            "url" => "https://a.test",
            "headers" => %{"X-Key" => "CANARY_FIXED_VALUE"},
            "auth" => %{"secret" => "CANARY_OPAQUE_VALUE"},
            "tools" => ["*"]
          }
        }
      })

    %{
      scope: scope,
      agent: agent,
      conn: log_in_user(conn, user),
      path: "/w/#{ws.slug}/agents/mcp-dev"
    }
  end

  test "safe projection, only URL changes preserve hidden values, invalid submit retains safe state",
       ctx do
    {:ok, agent} = Agents.get(ctx.scope, ctx.agent.name)
    form = AgentForm.edit(ctx.scope, 1, agent, %{configure: true})

    for sentinel <- ~w(CANARY_FIXED_VALUE CANARY_OPAQUE_VALUE),
        do: refute(inspect(form) =~ sentinel)

    assert form.mcp_config["docs"]["tools"] == ["*"]
    config = put_in(form.mcp_config, ["docs", "url"], "https://b.test")

    assert {:ok, _} =
             AgentForm.submit(form, ctx.scope, %{
               "agent" => Map.put(form.params, "mcp", Jason.encode!(config))
             })

    assert {:ok, profile} = Agents.execution_config(agent.actor_id)
    assert profile.extra_mcp_servers["docs"]["headers"]["X-Key"] == "CANARY_FIXED_VALUE"
    assert profile.extra_mcp_servers["docs"]["auth"]["secret"] == "CANARY_OPAQUE_VALUE"
    bad = put_in(config, ["docs", "url"], "bad")

    assert {:error, failed} =
             AgentForm.submit(form, ctx.scope, %{
               "agent" => Map.put(form.params, "mcp", Jason.encode!(bad))
             })

    for sentinel <- ~w(CANARY_FIXED_VALUE CANARY_OPAQUE_VALUE),
        do: refute(inspect(failed) =~ sentinel)

    {:ok, view, html} = live(ctx.conn, ctx.path <> "?panel=edit")
    for sentinel <- ~w(CANARY_FIXED_VALUE CANARY_OPAQUE_VALUE), do: refute(html =~ sentinel)
    assert in_portal?(view, "agent-panel", "[phx-hook=McpEditor]")
    refute inspect(:sys.get_state(view.pid)) =~ "CANARY_FIXED_VALUE"
  end

  test "personal definitions can be selected and owner gets check; member sees names only", ctx do
    {:ok, d} = McpServers.create(ctx.scope, %{name: "pw", config: %{"command" => "npx"}})
    {:ok, view, _} = live(ctx.conn, ctx.path <> "?panel=edit")

    assert in_portal?(
             view,
             "agent-panel",
             "input[name='agent[mcp_server_ids][]'][value='#{d.id}']"
           )

    assert has_element?(view, "#mcp-check")
    bob = user_fixture()
    member_fixture(ctx.scope.workspace, bob, :member)
    {:ok, other, html} = live(log_in_user(build_conn(), bob), ctx.path)
    refute has_element?(other, "#mcp-check")
    refute html =~ "a.test"
  end

  test "admin editor shows safe read-only summaries and no MCP actions", ctx do
    bob = user_fixture()
    member_fixture(ctx.scope.workspace, bob, :admin)
    {:ok, view, html} = live(log_in_user(build_conn(), bob), ctx.path <> "?panel=edit")
    assert in_portal?(view, "agent-panel", "#agent-mcp-names", "https://a.test")
    refute in_portal?(view, "agent-panel", "[phx-hook=McpEditor]")
    refute in_portal?(view, "agent-panel", "input[name='agent[mcp_server_ids][]']")
    refute html =~ "CANARY_FIXED_VALUE"
    refute inspect(:sys.get_state(view.pid)) =~ "CANARY_OPAQUE_VALUE"
  end

  test "validation replies serialize over the real Channel without values" do
    reply = HelmsmanWeb.McpEditor.validate_reply(%{"mcp" => %{"docs" => %{"url" => "bad"}}})
    assert [["docs.url", _]] = reply.errors
    assert Jason.encode!(reply)
    refute Jason.encode!(reply) =~ "bad"
  end

  test "browser validation and failed saves never retain newly entered secrets", ctx do
    {:ok, view, _} = live(ctx.conn, ctx.path <> "?panel=edit")

    raw = %{
      "docs" => %{
        "type" => "http",
        "url" => "bad",
        "headers" => %{"X-Key" => "NEW_FIXED_CANARY"},
        "auth" => %{"secret" => "NEW_OPAQUE_CANARY"}
      }
    }

    render_hook(view, "mcp_validate", %{"mcp" => raw})
    refute inspect(:sys.get_state(view.pid)) =~ "NEW_FIXED_CANARY"
    refute inspect(:sys.get_state(view.pid)) =~ "NEW_OPAQUE_CANARY"

    render_submit(view, "agent_form_submit", %{
      "agent" => %{"mcp" => Jason.encode!(raw)}
    })

    for sentinel <- ~w(NEW_FIXED_CANARY NEW_OPAQUE_CANARY) do
      refute render(view) =~ sentinel
      refute inspect(:sys.get_state(view.pid)) =~ sentinel
    end
  end

  test "local check timeout and offline reasons appear only for the owner", ctx do
    {daemon, _} = daemon_fixture(ctx.scope.user, %{workspace_ids: [ctx.scope.workspace.id]})
    runtime = runtime_fixture(ctx.scope.workspace, daemon, %{provider: "claude"})
    assert {:ok, _} = Agents.update(ctx.scope, ctx.agent.name, %{runtime_id: runtime.id})
    {:ok, view, _} = live(ctx.conn, ctx.path)
    view |> element("#mcp-check") |> render_click()
    assert has_element?(view, "p", "正在检查…")
    id = :sys.get_state(view.pid).socket.assigns.mcp_check_id
    send(Helmsman.McpServers.Check, {:timeout, id})
    _ = :sys.get_state(Helmsman.McpServers.Check)
    assert has_element?(view, "#mcp-check-error", "检查超时，请重试")

    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^runtime.id),
      set: [status: "offline"]
    )

    view |> element("#mcp-check") |> render_click()
    assert has_element?(view, "#mcp-check-error", "执行机器离线，无法检查")
  end

  test "legacy collision summary labels the inactive definition without exposing its config",
       ctx do
    {:ok, definition} =
      McpServers.create(ctx.scope, %{
        name: "personal",
        config: %{"command" => "npx", "auth" => "SHADOWED_CANARY"}
      })

    assert {:ok, _} = Agents.update(ctx.scope, ctx.agent.name, %{mcp_server_ids: [definition.id]})
    profile = Repo.get_by!(Helmsman.Agents.AgentProfile, actor_id: ctx.agent.actor_id)

    Repo.update!(
      Ecto.Changeset.change(profile, extra_mcp_servers: %{"PERSONAL" => %{"command" => "uvx"}})
    )

    {:ok, view, html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "[data-mcp-names]", "与自有服务器同名，未生效")
    refute html =~ "SHADOWED_CANARY"
  end
end

defmodule HelmsmanWeb.UserLive.McpServersTest do
  use HelmsmanWeb.ConnCase, async: true
  import HelmsmanWeb.PortalHelpers
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  alias Helmsman.Accounts.Scope
  alias Helmsman.McpServers

  test "authentication, isolation, masked list and safe editing", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, "/users/settings/mcp-servers")

    user = user_fixture()

    {:ok, d} =
      McpServers.create(Scope.for_user(user), %{
        name: "docs",
        config: %{"command" => "npx", "env" => %{"TOKEN" => "CANARY_PERSONAL"}}
      })

    {:ok, view, html} =
      live(log_in_user(conn, user), "/users/settings/mcp-servers?panel=edit&id=#{d.id}")

    assert has_element?(view, "#mcp-definition-#{d.id}")
    assert in_portal?(view, "mcp-definition-panel", "[phx-hook=McpEditor]")
    refute html =~ "CANARY_PERSONAL"
    refute inspect(:sys.get_state(view.pid)) =~ "CANARY_PERSONAL"

    {:ok, other, _} =
      live(log_in_user(build_conn(), user_fixture()), "/users/settings/mcp-servers")

    refute has_element?(other, "#mcp-definition-#{d.id}")
  end

  test "deletion confirms, lists in-use agents, then deletes after unbinding", %{conn: conn} do
    user = user_fixture()
    ws = Helmsman.WorkspacesFixtures.workspace_fixture(user)
    scope = Helmsman.WorkspacesFixtures.workspace_scope_fixture(user, ws)
    {:ok, definition} = McpServers.create(scope, %{name: "pw", config: %{"command" => "npx"}})

    agent =
      Helmsman.AgentsFixtures.managed_agent_fixture(scope, %{
        name: "bound",
        mcp_server_ids: [definition.id]
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/users/settings/mcp-servers")
    render_click(view, "delete")
    assert {:ok, _} = McpServers.get(scope, definition.id)
    render_click(view, "ask_delete", %{"id" => to_string(definition.id)})
    assert in_portal?(view, "delete-mcp-definition", "[data-confirm-primary]")
    render_click(view, "cancel_delete")
    assert {:ok, _} = McpServers.get(scope, definition.id)
    render_click(view, "ask_delete", %{"id" => to_string(definition.id)})
    assert render_click(view, "delete") =~ "#{ws.slug}/bound"
    assert {:ok, _} = Helmsman.Agents.update(scope, agent.name, %{mcp_server_ids: []})
    render_click(view, "ask_delete", %{"id" => to_string(definition.id)})
    render_click(view, "delete")
    refute has_element?(view, "#mcp-definition-#{definition.id}")
    assert {:error, :not_found} = McpServers.get(scope, definition.id)
  end

  test "failed name conflict stays under name and preserves safe edit state", %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)

    {:ok, first} =
      McpServers.create(scope, %{
        name: "first",
        config: %{"command" => "npx", "env" => %{"TOKEN" => "PERSONAL_CANARY"}}
      })

    {:ok, _} = McpServers.create(scope, %{name: "second", config: %{"command" => "uvx"}})

    {:ok, view, _} =
      live(log_in_user(conn, user), "/users/settings/mcp-servers?panel=edit&id=#{first.id}")

    {:ok, editable} = McpServers.editable(scope, first.id)

    render_submit(view, "save", %{
      "definition" => %{"name" => "second", "mcp" => Jason.encode!(%{"first" => editable})}
    })

    assert portal_attr(view, "mcp-definition-panel", "input[name='definition[name]']", "value") ==
             "second"

    assert in_portal?(view, "mcp-definition-panel", "[id=\"definition[name]-error\"] p")
    refute inspect(:sys.get_state(view.pid)) =~ "PERSONAL_CANARY"
    assert {:ok, %{name: "first"}} = McpServers.get(scope, first.id)
  end
end

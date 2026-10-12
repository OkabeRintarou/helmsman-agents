defmodule HelmsmanWeb.SettingsLive.TokensTest do
  @moduledoc "Spec web-workspace-settings 我的 Token / 新建 Token / 工作区全部 Token."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{ApiTokens, Repo, Workspaces}
  alias Helmsman.ApiTokens.ApiToken

  @plaintext ~r/hm_[a-z2-7]{52}/

  setup %{conn: conn} do
    _admin = user_fixture()
    owner = user_fixture(%{display_name: "olivia"})
    ws = workspace_fixture(owner, %{name: "Acme"})
    users = %{owner: owner}

    users =
      for {role, name} <- [admin: "bob", member: "carol", viewer: "dave"], into: users do
        user = user_fixture(%{display_name: name})
        member_fixture(ws, user, role)
        {role, user}
      end

    %{conn: conn, ws: ws, users: users, path: "/w/#{ws.slug}/settings/tokens"}
  end

  defp open(ctx, role, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[role]), path || ctx.path)

  defp scope(ctx, role), do: workspace_scope_fixture(ctx.users[role], ctx.ws)

  defp submit(view, params) do
    params =
      Map.merge(
        %{
          "name" => "laptop",
          "scopes" => ["mcp"],
          "expires_in" => "90",
          "default_agent_id" => ""
        },
        params
      )

    render_submit(view, "create", %{"token" => params})
  end

  defp secret(view),
    do: view |> portal_text("new-token-panel", "#token-secret-value") |> String.trim()

  describe "my tokens" do
    test "rows show the prefix, never the plaintext", ctx do
      %{api_token: laptop} =
        api_token_fixture(scope(ctx, :member), %{name: "laptop", scopes: ["mcp"]})

      %{api_token: old} =
        api_token_fixture(scope(ctx, :member), %{
          name: "old",
          expires_at: DateTime.add(DateTime.utc_now(:second), 30, :day)
        })

      old
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
      |> Repo.update!()

      %{api_token: gone} = api_token_fixture(scope(ctx, :member), %{name: "gone"})
      {:ok, _} = ApiTokens.revoke(scope(ctx, :member), gone.id)

      {:ok, view, html} = open(ctx, :member)
      row = "#own-tokens-#{laptop.id}"

      assert has_element?(view, "#own-token-#{laptop.id} [data-name]", "laptop")
      assert has_element?(view, "#own-token-#{laptop.id} [data-prefix]", "hm_#{laptop.prefix}…")
      assert has_element?(view, "#own-token-#{laptop.id} [data-scopes]", "mcp")
      assert has_element?(view, "#own-token-#{laptop.id} [data-agent]", "—")
      assert has_element?(view, "#own-token-#{laptop.id} [data-never-used]", "从未使用")
      assert has_element?(view, "#own-token-#{laptop.id} [data-expires]", "不过期")
      assert has_element?(view, "#{row}-revoke")

      assert has_element?(view, "#own-token-#{old.id} [data-expired]", "已过期")
      assert has_element?(view, "#own-token-#{gone.id} [data-revoked]", "已吊销")
      refute has_element?(view, "#own-tokens-#{gone.id}-revoke")

      refute html =~ @plaintext
      refute has_element?(view, "#all-tokens-section")
    end

    test "empty state", ctx do
      {:ok, view, _html} = open(ctx, :member)
      assert render(view) =~ "还没有 Token"
    end

    test "a user demoted to viewer revokes their own token", ctx do
      membership = Workspaces.get_membership(ctx.ws.id, ctx.users.viewer.id)
      membership |> Ecto.Changeset.change(role: :member) |> Repo.update!()
      %{api_token: own} = api_token_fixture(scope(ctx, :viewer), %{name: "x"})
      membership |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

      {:ok, view, _html} = open(ctx, :viewer)

      view |> element("#own-tokens-#{own.id}-revoke") |> render_click()

      assert in_portal?(
               view,
               "revoke-token-dialog",
               "#revoke-token-dialog-title",
               "吊销 #{own.name}？"
             )

      assert in_portal?(view, "revoke-token-dialog", "#revoke-token-dialog-description", "立即无法访问")

      html = render_click(view, "revoke", %{"id" => own.id})
      assert html =~ "Token 已吊销"
      assert has_element?(view, "#own-token-#{own.id} [data-revoked]", "已吊销")
      refute has_element?(view, "#own-tokens-#{own.id}-revoke")
    end
  end

  describe "new token" do
    test "an MCP token shows the plaintext and the claude command once", ctx do
      {:ok, view, _html} = open(ctx, :member)
      view |> element("#new-token-button") |> render_click()
      assert_patch(view, ctx.path <> "?panel=new-token")
      assert open?(view, "new-token-panel")

      submit(view, %{})

      token = secret(view)
      assert token =~ @plaintext
      assert {:ok, %{user: %{id: user_id}}} = ApiTokens.authenticate(token, "mcp")
      assert user_id == ctx.users.member.id

      command =
        view |> portal_text("new-token-panel", "#token-mcp-command-value") |> String.trim()

      assert command ==
               ~s(claude mcp add --transport http helmsman #{HelmsmanWeb.Endpoint.url()}/mcp --header "Authorization: Bearer #{token}")

      assert in_portal?(view, "new-token-panel", "#token-secret-copy")
      assert in_portal?(view, "new-token-panel", "#token-mcp-command-copy")

      [created] = elem(ApiTokens.list_own(scope(ctx, :member)), 1)

      assert_in_delta DateTime.to_unix(created.expires_at),
                      DateTime.to_unix(DateTime.add(DateTime.utc_now(), 90, :day)),
                      60

      render_patch(view, ctx.path)
      assert has_element?(view, "#own-token-#{created.id} [data-name]", "laptop")
      refute render(view) =~ token
    end

    test "without mcp there is no command", ctx do
      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=new-token")
      submit(view, %{"scopes" => ["api:read"], "expires_in" => "never"})

      assert secret(view) =~ @plaintext
      refute in_portal?(view, "new-token-panel", "#token-mcp-command")
      [created] = elem(ApiTokens.list_own(scope(ctx, :member)), 1)
      assert created.expires_at == nil
    end

    test "no scope selected", ctx do
      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=new-token")

      render_submit(view, "create", %{
        "token" => %{"name" => "x", "scopes" => [""], "expires_in" => "30"}
      })

      assert open?(view, "new-token-panel")
      assert in_portal?(view, "new-token-panel", "#token-scopes-error", "至少选择一项")
      assert elem(ApiTokens.list_own(scope(ctx, :member)), 1) == []
    end

    test "name errors keep the other input", ctx do
      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=new-token")

      for name <- ["", String.duplicate("a", 65)] do
        submit(view, %{
          "name" => name,
          "scopes" => ["api:read", "api:write"],
          "expires_in" => "365"
        })

        assert in_portal?(view, "new-token-panel", "#token-name-error")
        assert portal_attr(view, "new-token-panel", "#token-scope-api-read", "checked")
        assert portal_attr(view, "new-token-panel", "#token-scope-api-write", "checked")
        refute portal_attr(view, "new-token-panel", "#token-scope-mcp", "checked")

        assert portal_attr(view, "new-token-panel", "#token-expires option[selected]", "value") ==
                 "365"
      end
    end

    test "the plaintext is gone after a reload", ctx do
      url = ctx.path <> "?panel=new-token"
      {:ok, view, _html} = open(ctx, :member, url)
      submit(view, %{})
      token = secret(view)

      {:ok, view, html} = open(ctx, :member, url)
      refute html =~ token
      refute render(view) =~ @plaintext
      refute in_portal?(view, "new-token-panel", "#token-result")
    end

    test "viewers get a disabled button", ctx do
      {:ok, view, html} = open(ctx, :viewer)
      assert has_element?(view, ~s(#new-token-button[aria-disabled="true"]))
      assert html =~ "只读成员不能创建 Token"

      {:ok, view, _html} = open(ctx, :viewer, ctx.path <> "?panel=new-token")
      refute open?(view, "new-token-panel")
    end
  end

  describe "default agent" do
    test "only enabled agents of one's own are offered", ctx do
      carol = ctx.users.member
      agent = agent_fixture(ctx.ws, carol, "carol-claude")
      agent_fixture(ctx.ws, carol, "carol-old", %{disabled_at: DateTime.utc_now(:second)})
      agent_fixture(ctx.ws, ctx.users.admin, "bob-agent")

      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=new-token")

      options =
        view
        |> portal("new-token-panel")
        |> LazyHTML.query("#token-default-agent option")
        |> LazyHTML.text()

      assert options == "无carol-claude"

      submit(view, %{"default_agent_id" => to_string(agent.id)})
      [created] = elem(ApiTokens.list_own(scope(ctx, :member)), 1)
      assert created.default_agent_id == agent.id

      render_patch(view, ctx.path)
      assert has_element?(view, "#own-token-#{created.id} [data-agent]", "carol-claude")
    end

    test "without agents an explanation replaces the select", ctx do
      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=new-token")
      refute in_portal?(view, "new-token-panel", "#token-default-agent")
      assert in_portal?(view, "new-token-panel", "#token-no-agents", "外接 Agent 第一次连接时会自动创建身份")
    end
  end

  describe "all tokens" do
    test "an admin revokes someone else's token", ctx do
      %{api_token: ci} = api_token_fixture(scope(ctx, :member), %{name: "ci"})
      %{api_token: mine} = api_token_fixture(scope(ctx, :admin), %{name: "mine"})
      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(view, "#all-token-#{ci.id} [data-user]", "carol")
      assert has_element?(view, "#all-token-#{mine.id} [data-user]", "bob")
      refute has_element?(view, "#own-token-#{ci.id}")

      view |> element("#all-tokens-#{ci.id}-revoke") |> render_click()
      html = render_click(view, "revoke", %{"id" => ci.id})
      assert html =~ "Token 已吊销"
      assert has_element?(view, "#all-token-#{ci.id} [data-revoked]", "已吊销")
      assert Repo.get!(ApiToken, ci.id).revoked_at
    end

    test "revoking one's own token there updates 我的 Token too", ctx do
      %{api_token: mine} = api_token_fixture(scope(ctx, :admin), %{name: "mine"})
      {:ok, view, _html} = open(ctx, :admin)

      render_click(view, "revoke", %{"id" => mine.id})
      assert has_element?(view, "#all-token-#{mine.id} [data-revoked]")
      assert has_element?(view, "#own-token-#{mine.id} [data-revoked]")
    end

    test "members do not see it", ctx do
      {:ok, view, _html} = open(ctx, :member)
      refute has_element?(view, "#all-tokens-section")
      assert Workspaces.get_membership(ctx.ws.id, ctx.users.member.id).role == :member
    end
  end
end

defmodule HelmsmanWeb.InvitationLiveTest do
  @moduledoc "Spec web-workspace-entry 邀请预览页 / 接受邀请."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Invitations, Repo, Workspaces}
  alias HelmsmanWeb.InvitationLive

  setup do
    # The first user becomes the instance admin and owns the workspace `default`.
    _admin = user_fixture()
    bob = user_fixture(%{display_name: "bob"})
    ws = workspace_fixture(bob, %{name: "Acme"})
    scope = workspace_scope_fixture(bob, ws)
    %{token: token, invitation: invitation} = invitation_fixture(scope)
    %{bob: bob, ws: ws, scope: scope, token: token, invitation: invitation}
  end

  defp card(view), do: view |> element("#invitation") |> render()

  describe "preview" do
    test "a visitor sees who invites whom where", %{conn: conn, token: token} do
      {:ok, view, html} = live(conn, ~p"/invite/#{token}")

      assert has_element?(view, "#invitation-summary", "bob 邀请你以「成员」身份加入 Acme")
      assert has_element?(view, "#invitation-expires", "过期")
      assert has_element?(view, ~s(#invitation-log-in[href="/users/log-in"]), "登录后接受")

      assert has_element?(
               view,
               ~s(#invitation-register[href="/users/register?invitation=#{token}"]),
               "注册新账号"
             )

      refute has_element?(view, "#invitation-accept")
      refute html =~ "#invitation-email-bound"
    end

    test "an invitation bound to an email does not show it", %{conn: conn, scope: scope} do
      %{token: token} = invitation_fixture(scope, %{email: "carol@x.com"})
      {:ok, view, html} = live(conn, ~p"/invite/#{token}")

      assert has_element?(view, "#invitation-email-bound", "此邀请只能由受邀邮箱的账号接受")
      refute html =~ "carol@x.com"
    end

    test "accepted and unknown links look the same", %{conn: conn, token: token} do
      {:ok, _} = Invitations.accept(user_fixture(), token)

      {:ok, accepted, _html} = live(conn, ~p"/invite/#{token}")
      {:ok, unknown, _html} = live(conn, ~p"/invite/nope")

      assert card(accepted) =~ "邀请无效或已过期"
      assert has_element?(accepted, ~s(#invitation a[href="/"]), "返回首页")
      assert card(accepted) == card(unknown)
    end

    test "expired, revoked and unknown links render the same body",
         %{conn: conn, scope: scope} do
      %{token: expired, invitation: invitation} = invitation_fixture(scope)

      invitation
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> Repo.update!()

      %{token: revoked, invitation: to_revoke} = invitation_fixture(scope)
      {:ok, _} = Invitations.revoke(scope, to_revoke.id)

      cards =
        for token <- [expired, revoked, "unknown-token"] do
          {:ok, view, _html} = live(conn, ~p"/invite/#{token}")
          card(view)
        end

      assert [one] = Enum.uniq(cards)
      assert one =~ "邀请无效或已过期"
    end

    test "a logged-in user sees the account, 接受并加入 and 换个账号", %{conn: conn, token: token} do
      carol = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, carol), ~p"/invite/#{token}")

      assert has_element?(view, "#invitation-account", carol.email)
      assert has_element?(view, "#invitation-accept", "接受并加入")

      assert has_element?(
               view,
               ~s(#invitation-switch-account[data-method="delete"][href="/users/log-out?return_to=%2Finvite%2F#{token}"]),
               "换个账号"
             )

      refute has_element?(view, "#invitation-log-in")
    end
  end

  describe "accepting" do
    test "joins and enters the workspace", %{conn: conn, token: token, ws: ws} do
      carol = user_fixture()
      conn = log_in_user(conn, carol)
      {:ok, view, _html} = live(conn, ~p"/invite/#{token}")

      {:ok, conn} =
        view
        |> element("#invitation-accept")
        |> render_click()
        |> follow_redirect(conn, "/w/#{ws.slug}")

      assert html_response(conn, 200) =~ "已加入 Acme"
      assert Enum.any?(Workspaces.list_for_user(carol), &(&1.workspace.id == ws.id))

      {:ok, view, _html} = live(conn, "/w/#{ws.slug}")
      assert has_element?(view, "#hm-ws-#{ws.slug}", "Acme")
    end

    test "the accept button disables itself while submitting", %{conn: conn, token: token} do
      {:ok, view, _html} = live(log_in_user(conn, user_fixture()), ~p"/invite/#{token}")
      assert has_element?(view, "#invitation-accept[phx-disable-with]")
    end

    test "an email mismatch keeps the invitation usable", %{conn: conn, scope: scope} do
      %{token: token} = invitation_fixture(scope, %{email: "bob@x.com"})
      eve = user_fixture(%{email: "eve@x.com"})
      {:ok, view, _html} = live(log_in_user(conn, eve), ~p"/invite/#{token}")

      view |> element("#invitation-accept") |> render_click()

      assert has_element?(view, "#invitation-error", "此邀请属于另一个邮箱，请用受邀邮箱的账号登录")
      assert has_element?(view, "#invitation-switch-account.btn-primary")
      assert {:ok, _} = Invitations.preview(token)
    end

    test "an existing member is told so", %{conn: conn, token: token, bob: bob, ws: ws} do
      {:ok, view, _html} = live(log_in_user(conn, bob), ~p"/invite/#{token}")
      view |> element("#invitation-accept") |> render_click()

      assert has_element?(view, "#invitation-error", "你已经是 Acme 的成员")
      assert has_element?(view, ~s(#invitation-enter[href="/"]), "进入工作区")
      assert [_] = Enum.filter(Workspaces.list_for_user(bob), &(&1.workspace.id == ws.id))
    end

    test "revoked after opening the page", %{conn: conn, token: token, scope: scope} do
      carol = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, carol), ~p"/invite/#{token}")

      [pending] = elem(Invitations.list_pending(scope), 1)
      {:ok, _} = Invitations.revoke(scope, pending.id)

      view |> element("#invitation-accept") |> render_click()
      assert card(view) =~ "邀请无效或已过期"
      refute has_element?(view, "#invitation-accept")
      assert Workspaces.list_for_user(carol) == []
    end

    test "an unconfirmed email must be confirmed first", %{conn: conn, scope: scope} do
      user = unconfirmed_user_fixture()
      %{token: token} = invitation_fixture(scope, %{email: user.email})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/invite/#{token}")
      view |> element("#invitation-accept") |> render_click()
      assert has_element?(view, "#invitation-error", "请先确认邮箱后再接受邀请")
    end

    test "other errors ask to retry" do
      assert InvitationLive.error_message(:name_unavailable, "Acme") == "加入失败，请稍后重试"
    end
  end
end

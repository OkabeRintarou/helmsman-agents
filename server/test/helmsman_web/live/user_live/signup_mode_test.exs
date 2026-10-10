defmodule HelmsmanWeb.UserLive.SignupModeTest do
  # Switches the global signup mode.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts
  alias Helmsman.Invitations
  alias Helmsman.Repo

  defp put_signup_mode(mode) do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :signup_mode, mode)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)
  end

  describe "invite mode with existing users" do
    setup do
      put_signup_mode(:invite)
      user_fixture()
      :ok
    end

    test "login page has no registration link", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")
      refute has_element?(lv, ~s(a[href="/users/register"]))
      # The dead render includes the root layout.
      refute html =~ ~s(href="/users/register")
    end

    test "registration page explains signup is invite-only and has no form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")
      assert has_element?(lv, "#signup_closed")
      assert html =~ "注册仅限受邀"
      refute has_element?(lv, "#registration_form")
    end

    test "a forged submit event is rejected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      html = render_submit(lv, "save", %{"user" => %{"email" => email}})

      assert html =~ "注册仅限受邀"
      refute Accounts.get_user_by_email(email)
    end
  end

  describe "invite mode with an invitation link" do
    setup do
      put_signup_mode(:invite)
      owner = user_fixture()
      workspace = workspace_fixture(owner, %{name: "Acme Corp"})
      %{scope: workspace_scope_fixture(owner, workspace)}
    end

    test "a valid invitation shows the workspace and registers without consuming it",
         %{conn: conn, scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      assert lv |> element("#invitation_summary") |> render() =~ "你被邀请加入 Acme Corp"
      refute has_element?(lv, "#signup_closed")

      email = unique_user_email()

      {:ok, _lv, _html} =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Accounts.get_user_by_email(email)
      refute Repo.reload!(invitation).accepted_at
    end

    test "an invitation that became invalid before submitting is refused",
         %{conn: conn, scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      {:ok, _} = Invitations.revoke(scope, invitation.id)
      email = unique_user_email()

      html =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()

      assert html =~ "注册仅限受邀"
      assert has_element?(lv, "#signup_closed")
      refute has_element?(lv, "#invitation_summary")
      refute Accounts.get_user_by_email(email)
    end

    test "an invalid invitation explains signup is invite-only", %{conn: conn, scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)
      {:ok, _} = Invitations.revoke(scope, invitation.id)

      for token <- [token, "no-such-token"] do
        {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
        assert has_element?(lv, "#signup_closed")
        refute has_element?(lv, "#invitation_summary")
        refute has_element?(lv, "#registration_form")
      end
    end
  end

  describe "invite mode on an empty instance" do
    setup do
      put_signup_mode(:invite)
    end

    test "login page links to registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, ~s(a[href="/users/register"]))
    end

    test "the first user registers and becomes the instance admin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      {:ok, _lv, _html} =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Accounts.get_user_by_email(email).instance_admin
    end
  end

  describe "open mode with existing users" do
    setup do
      put_signup_mode(:open)
      user_fixture()
      :ok
    end

    test "login page links to registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, ~s(a[href="/users/register"]))
    end

    test "registration form is shown and creates a non-admin user", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#signup_closed")
      email = unique_user_email()

      {:ok, _lv, _html} =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      refute Accounts.get_user_by_email(email).instance_admin
    end
  end
end

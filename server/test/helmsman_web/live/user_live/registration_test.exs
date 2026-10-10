defmodule HelmsmanWeb.UserLive.RegistrationTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "注册账号"
      assert html =~ "登录"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "注册账号"
      assert result =~ "必须包含 @ 且不能有空格"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               ~r/确认邮件已发送到 .*，请打开邮件中的链接确认账号/
    end

    test "derives the display name from the email when left blank", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _lv, _html} =
        lv
        |> form("#registration_form", user: %{"email" => "alice.w@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Helmsman.Accounts.get_user_by_email("alice.w@example.com").display_name == "alice.w"
    end

    test "stores the given display name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      {:ok, _lv, _html} =
        lv
        |> form("#registration_form", user: %{"email" => email, "display_name" => " Alice "})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Helmsman.Accounts.get_user_by_email(email).display_name == "Alice"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "已被占用"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "登录")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "登录"
    end
  end
end

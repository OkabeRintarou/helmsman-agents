defmodule HelmsmanWeb.UserSessionControllerTest do
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  alias Helmsman.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request: `/` only redirects (add-workspace-settings-ui D3)
      conn = get(conn, ~p"/")
      assert redirected_to(conn) =~ ~r{^/(w/|workspaces/new)}
      conn = get(recycle(conn), ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ user.email
    end

    test "sets the session cookie with HttpOnly and SameSite=Lax", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      session_cookie =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.find(&String.starts_with?(&1, "_helmsman_key="))

      assert session_cookie =~ "HttpOnly"
      assert session_cookie =~ "SameSite=Lax"
      # Secure is only compiled in for production builds (config/prod.exs).
      refute session_cookie =~ ~r/secure/i
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_helmsman_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "欢迎回来！"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "邮箱或密码错误"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    for token <- ["%%invalid%%", "", "a.b/c"] do
      test "treats the malformed token #{inspect(token)} as an invalid link", %{conn: conn} do
        conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => unquote(token)}})

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "链接无效或已过期。"

        assert redirected_to(conn) == ~p"/users/log-in"
        refute get_session(conn, :user_token)
      end
    end

    test "treats a non-string token as an invalid link", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => %{"x" => "1"}}})
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end
  end

  describe "POST /users/update-password" do
    setup %{user: user} do
      %{user: set_password(user)}
    end

    defp post_update_password(conn, user, authenticated_minutes_ago, password) do
      conn
      |> log_in_user(user,
        token_authenticated_at:
          DateTime.add(DateTime.utc_now(:second), -authenticated_minutes_ago, :minute)
      )
      |> post(~p"/users/update-password", %{
        "user" => %{
          "email" => user.email,
          "password" => password,
          "password_confirmation" => password
        }
      })
    end

    test "updates the password within 20 minutes of logging in", %{conn: conn, user: user} do
      conn = post_update_password(conn, user, 19, "new valid password")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "asks to log in again when sudo mode has expired", %{conn: conn, user: user} do
      conn = post_update_password(conn, user, 21, "new valid password")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "需要重新登录才能修改邮箱或密码。"

      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "rejects an invalid password without crashing", %{conn: conn, user: user} do
      conn = post_update_password(conn, user, 1, "short")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request: `/` only redirects (add-workspace-settings-ui D3)
      conn = get(conn, ~p"/")
      assert redirected_to(conn) =~ ~r{^/(w/|workspaces/new)}
      conn = get(recycle(conn), ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ user.email
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "账号已确认。"

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request: `/` only redirects (add-workspace-settings-ui D3)
      conn = get(conn, ~p"/")
      assert redirected_to(conn) =~ ~r{^/(w/|workspaces/new)}
      conn = get(recycle(conn), ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ user.email
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "链接无效或已过期。"

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "已退出登录"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "已退出登录"
    end
  end
end

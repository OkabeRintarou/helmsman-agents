defmodule HelmsmanWeb.UserLive.SettingsTest do
  use HelmsmanWeb.ConnCase, async: true

  alias Helmsman.Accounts
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Swoosh.TestAssertions

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)

  # Simulates time passing on an open page: the LiveView keeps the user it
  # loaded at mount, whose authenticated_at decides sudo mode.
  defp expire_sudo_mode(lv) do
    :sys.replace_state(lv.pid, fn state ->
      put_in(
        state,
        [
          :socket,
          Access.key(:assigns),
          :current_scope,
          Access.key(:user),
          Access.key(:authenticated_at)
        ],
        minutes_ago(21)
      )
    end)
  end

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "修改邮箱"
      assert html =~ "保存密码"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "请先登录。"} = flash
    end

    test "shows email and password forms 19 minutes after logging in", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: minutes_ago(19))
        |> live(~p"/users/settings")

      assert has_element?(lv, "#email_form")
      assert has_element?(lv, "#password_form")
      refute has_element?(lv, "#reauthenticate_notice")
    end

    test "hides email and password forms if user is not in sudo mode", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: minutes_ago(21))
        |> live(~p"/users/settings")

      assert has_element?(lv, "#display_name_form")
      assert has_element?(lv, "#reauthenticate_notice")
      refute has_element?(lv, "#email_form")
      refute has_element?(lv, "#password_form")
    end
  end

  describe "sudo mode expiring while the page is open" do
    setup %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user, token_authenticated_at: minutes_ago(1))
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      expire_sudo_mode(lv)
      # Drop the log in email sent by user_fixture/0.
      assert_email_sent()
      %{lv: lv, user: user}
    end

    test "submitting the email form asks to log in again", %{lv: lv, user: user} do
      html =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert html =~ "需要重新登录才能修改邮箱或密码。"
      assert has_element?(lv, "#reauthenticate_notice")
      refute has_element?(lv, "#email_form")
      assert has_element?(lv, "#display_name_form")
      assert_no_email_sent()
      assert Accounts.get_user!(user.id).email == user.email
    end

    test "submitting the password form asks to log in again", %{lv: lv, user: user} do
      form =
        form(lv, "#password_form", %{
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      html = render_submit(form)

      assert html =~ "需要重新登录才能修改邮箱或密码。"
      refute has_element?(lv, "#password_form")
      refute has_element?(lv, ~s(#password_form[phx-trigger-action]))
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "the display name can still be changed", %{lv: lv, user: user} do
      lv
      |> form("#display_name_form", %{"user" => %{"display_name" => "Still Me"}})
      |> render_submit()

      assert Accounts.get_user!(user.id).display_name == "Still Me"
    end
  end

  describe "update display name form" do
    setup %{conn: conn} do
      user = user_fixture()

      conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -30, :minute)
        )

      %{conn: conn, user: user}
    end

    test "updates the display name without sudo mode", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#display_name_form", %{"user" => %{"display_name" => "Captain Nemo"}})
        |> render_submit()

      assert result =~ "显示名已更新"

      assert lv |> element("#display_name_form input[name='user[display_name]']") |> render() =~
               ~s(value="Captain Nemo")

      assert Accounts.get_user!(user.id).display_name == "Captain Nemo"
    end

    test "renders errors and keeps the name if it is too long", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#display_name_form", %{
          "user" => %{"display_name" => String.duplicate("x", 65)}
        })
        |> render_submit()

      assert result =~ "最多 64 个字符"
      assert Accounts.get_user!(user.id).display_name == user.display_name
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "确认链接已发送到新邮箱"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "修改邮箱"
      assert result =~ "必须包含 @ 且不能有空格"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "修改邮箱"
      assert result =~ "没有变化"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "密码已更新"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "保存密码"
      assert result =~ "至少 12 个字符"
      assert result =~ "与密码不一致"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "保存密码"
      assert result =~ "至少 12 个字符"
      assert result =~ "与密码不一致"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "邮箱已修改。"
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "邮箱修改链接无效或已过期。"
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "邮箱修改链接无效或已过期。"
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "请先登录。"
    end

    test "works 19 minutes after logging in", %{conn: conn, user: user, token: token} do
      conn = log_in_user(conn, user, token_authenticated_at: minutes_ago(19))

      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: "/users/settings", flash: flash}} = redirect
      assert flash["info"] == "邮箱已修改。"
      refute Accounts.get_user_by_email(user.email)
    end

    test "requires sudo mode", %{conn: conn, user: user, token: token} do
      conn = log_in_user(conn, user, token_authenticated_at: minutes_ago(21))

      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "请重新登录以验证身份。"} = flash
      assert Accounts.get_user_by_email(user.email)
    end
  end
end

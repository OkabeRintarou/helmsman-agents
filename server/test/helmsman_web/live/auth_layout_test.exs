defmodule HelmsmanWeb.AuthLayoutTest do
  @moduledoc """
  Authentication pages use `Layouts.auth` (centered card, no shell) and the account
  settings page `Layouts.personal` (no shell either); their form buttons submit
  (`<.button>` defaults to `type="button"`).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures

  defp assert_auth_layout(view) do
    assert has_element?(view, "main#hm-main")
    refute has_element?(view, "#hm-sidebar")
    refute has_element?(view, "#hm-shell")
  end

  test "log-in page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log-in")

    assert_auth_layout(view)
    assert has_element?(view, ~s(#login_form_magic button[type="submit"]), "发送登录链接")

    assert has_element?(
             view,
             ~s(#login_form_password button[type="submit"][name="user[remember_me]"][value="true"])
           )

    assert has_element?(view, ~s{#login_form_password button[type="submit"]:not([name])})
  end

  test "registration page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/register")

    assert_auth_layout(view)
    # config/test.exs sets signup_mode :open.
    assert has_element?(view, ~s(#registration_form button[type="submit"]))
  end

  test "magic link confirmation page", %{conn: conn} do
    user = unconfirmed_user_fixture()
    token = extract_user_token(&Helmsman.Accounts.deliver_login_instructions(user, &1))

    {:ok, view, _html} = live(conn, ~p"/users/log-in/#{token}")

    assert_auth_layout(view)

    assert has_element?(
             view,
             ~s(#confirmation_form button[type="submit"][name="user[remember_me]"])
           )
  end

  test "account settings page", %{conn: conn} do
    {:ok, view, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")

    assert_auth_layout(view)
    assert has_element?(view, ~s(#display_name_form button[type="submit"]))
    assert has_element?(view, ~s(#email_form button[type="submit"]))
    assert has_element?(view, ~s(#password_form button[type="submit"]))
  end
end

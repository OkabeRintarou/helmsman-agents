defmodule HelmsmanWeb.InvitationReturnTest do
  @moduledoc "Spec web-workspace-entry 登录或注册后回到邀请页 (design D4)."
  # Switches the global signup mode.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Workspaces

  setup do
    _admin = user_fixture()
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    %{token: token} = invitation_fixture(workspace_scope_fixture(owner, ws))
    %{token: token, ws: ws}
  end

  test "logging in with a password returns to the invitation", %{conn: conn, token: token} do
    user = set_password(user_fixture())

    conn = get(conn, ~p"/invite/#{token}")

    conn =
      post(recycle(conn), ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == "/invite/#{token}"

    {:ok, view, _html} = live(recycle(conn), ~p"/invite/#{token}")
    assert has_element?(view, "#invitation-accept", "接受并加入")
    assert Workspaces.list_for_user(user) == []
  end

  test "registering from the invitation returns to it after the login link",
       %{conn: conn, token: token} do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :signup_mode, :invite)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)

    conn = get(conn, ~p"/invite/#{token}")
    {:ok, view, _html} = live(recycle(conn), ~p"/users/register?invitation=#{token}")
    email = unique_user_email()

    view
    |> form("#registration_form", user: %{"email" => email})
    |> render_submit()

    # Fixtures mailed other users before; pick the mail to the new account.
    assert_receive {:email, %Swoosh.Email{to: [{_, ^email}], text_body: body}}
    [_, login_token] = Regex.run(~r{/users/log-in/([A-Za-z0-9_-]+)}, body)

    conn = post(recycle(conn), ~p"/users/log-in", %{"user" => %{"token" => login_token}})
    assert redirected_to(conn) == "/invite/#{token}"

    user = Helmsman.Accounts.get_user_by_email(email)
    assert Workspaces.list_for_user(user) == []
  end
end

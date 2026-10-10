defmodule HelmsmanWeb.WorkspaceLiveTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Workspaces

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner, %{slug: "acme", name: "Acme Inc."})
    %{owner: owner, workspace: workspace}
  end

  test "a member sees the workspace name and their role",
       %{conn: conn, workspace: ws} do
    viewer = user_fixture()
    member_fixture(ws, viewer, :viewer)

    {:ok, lv, _html} = conn |> log_in_user(viewer) |> live(~p"/w/acme")

    assert lv |> element("#workspace-name") |> render() =~ "Acme Inc."
    assert lv |> element("#workspace-role") |> render() =~ "viewer"
  end

  test "the scope carries the workspace, role and human identity",
       %{conn: conn, owner: owner, workspace: ws} do
    {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/w/ACME")

    scope = :sys.get_state(lv.pid).socket.assigns.current_scope
    assert scope.workspace.id == ws.id
    assert scope.role == :owner
    assert scope.actor.kind == :human
    assert scope.actor.user_id == owner.id
    assert scope.via == :web
  end

  test "non-members and unknown slugs get the same 404", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {404, _headers, not_member} = assert_error_sent(404, fn -> get(conn, ~p"/w/acme") end)
    {404, _headers, unknown} = assert_error_sent(404, fn -> get(conn, ~p"/w/no-such-ws") end)

    assert not_member == unknown
  end

  test "a live mount by a non-member raises the not-found error", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert_raise HelmsmanWeb.NotFoundError, fn -> live(conn, ~p"/w/acme") end
  end

  test "an anonymous visitor is redirected to the login page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/w/acme")
  end

  test "after a slug change the old address is a 404",
       %{conn: conn, owner: owner, workspace: ws} do
    {:ok, _} = Workspaces.update(workspace_scope_fixture(owner, ws), %{slug: "acme-cn"})
    conn = log_in_user(conn, owner)

    assert {:ok, _lv, _html} = live(conn, ~p"/w/acme-cn")
    assert_error_sent 404, fn -> get(conn, ~p"/w/acme") end
  end
end

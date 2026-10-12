defmodule HelmsmanWeb.SettingsLive.GeneralTest do
  @moduledoc "Spec web-workspace-settings 常规设置 / 退出工作区."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Members, Workspaces}

  setup do
    _admin = user_fixture()
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    admin = user_fixture()
    member_fixture(ws, admin, :admin)
    member = user_fixture()
    member_fixture(ws, member, :member)
    %{owner: owner, admin: admin, member: member, ws: ws}
  end

  defp open(conn, user, ws), do: live(log_in_user(conn, user), "/w/#{ws.slug}/settings")

  describe "name and slug" do
    test "an admin renames the workspace", %{conn: conn, admin: admin, ws: ws} do
      {:ok, view, _html} = open(conn, admin, ws)

      html =
        view
        |> element("#workspace-name-form")
        |> render_submit(%{"workspace" => %{"name" => "Acme 中国"}})

      assert html =~ "已保存"
      assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme 中国")
      assert_push_event(view, "hm:title-suffix", %{suffix: " · Acme 中国"})
      assert Workspaces.get_by_slug(ws.slug).name == "Acme 中国"
    end

    test "an admin sees the slug read-only", %{conn: conn, admin: admin, ws: ws} do
      {:ok, view, _html} = open(conn, admin, ws)
      refute has_element?(view, "#workspace-slug-form")
      assert has_element?(view, "#workspace-slug-text", "/w/#{ws.slug}")
      assert has_element?(view, "#workspace-slug-owner-only", "只有所有者能修改地址")
    end

    test "name errors stay under the field", %{conn: conn, admin: admin, ws: ws} do
      {:ok, view, _html} = open(conn, admin, ws)
      long = String.duplicate("名", 81)

      view
      |> element("#workspace-name-form")
      |> render_submit(%{"workspace" => %{"name" => long}})

      assert has_element?(view, "#workspace-name-error", "80")
      assert has_element?(view, ~s(#workspace-name[value="#{long}"]))
      assert Workspaces.get_by_slug(ws.slug).name == "Acme"
    end

    test "an owner changes the slug after confirming", %{conn: conn, owner: owner, ws: ws} do
      new_slug = unique_workspace_slug()
      conn = log_in_user(conn, owner)
      {:ok, view, _html} = live(conn, "/w/#{ws.slug}/settings")

      view
      |> element("#workspace-slug-form")
      |> render_submit(%{"workspace" => %{"slug" => new_slug}})

      assert in_portal?(view, "slug-dialog", "#slug-dialog", "修改后 /w/#{ws.slug} 的所有链接将失效")
      assert Workspaces.get_by_slug(ws.slug)

      # The confirm button pushes the dialog's cancel, then the confirm event.
      assert portal_attr(view, "slug-dialog", "#slug-dialog-confirm", "phx-click") =~
               "confirm_slug"

      render_click(view, "cancel_slug", %{})

      {:ok, view, html} =
        view
        |> render_click("confirm_slug", %{"slug" => new_slug})
        |> follow_redirect(conn, "/w/#{new_slug}/settings")

      assert length(String.split(html, "工作区地址已改为 /w/#{new_slug}")) == 2
      refute_redirected(view)
      assert has_element?(view, ~s(nav[aria-label="设置"] a[aria-current="page"]), "常规")
      refute Workspaces.get_by_slug(ws.slug)
    end

    test "cancelling keeps the slug and the input", %{conn: conn, owner: owner, ws: ws} do
      {:ok, view, _html} = open(conn, owner, ws)

      view
      |> element("#workspace-slug-form")
      |> render_submit(%{"workspace" => %{"slug" => "acme-new"}})

      assert open?(view, "slug-dialog")
      render_click(view, "cancel_slug", %{})

      refute open?(view, "slug-dialog")
      assert has_element?(view, ~s(#workspace-slug[value="acme-new"]))
      assert Workspaces.get_by_slug(ws.slug)
    end

    test "an invalid slug is reported while typing", %{conn: conn, owner: owner, ws: ws} do
      {:ok, view, _html} = open(conn, owner, ws)

      view
      |> element("#workspace-slug-form")
      |> render_change(%{"workspace" => %{"slug" => "-x"}})

      assert has_element?(view, "#workspace-slug-error", "须为 2–39 位")
    end

    test "a member sees only read-only text", %{conn: conn, member: member, ws: ws} do
      {:ok, view, _html} = open(conn, member, ws)

      assert has_element?(view, "#workspace-name-text", "Acme")
      assert has_element?(view, "#workspace-slug-text", "/w/#{ws.slug}")
      refute has_element?(view, "#workspace-name-form")
      refute has_element?(view, "#workspace-slug-form")
      refute has_element?(view, "#workspace-slug-owner-only")
      refute has_element?(view, "#workspace-section button")
    end
  end

  describe "leaving" do
    test "a member leaves", %{conn: conn, member: member, ws: ws} do
      conn = log_in_user(conn, member)
      {:ok, view, _html} = live(conn, "/w/#{ws.slug}/settings")

      view |> element("#leave-workspace") |> render_click()
      assert in_portal?(view, "leave-dialog", "#leave-dialog-title", "退出 Acme？")
      assert in_portal?(view, "leave-dialog", "#leave-dialog-description", "Token 将被吊销")

      {:ok, conn} =
        view
        |> render_click("leave", %{})
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "你已退出 Acme"
      refute Enum.any?(Workspaces.list_for_user(member), &(&1.workspace.id == ws.id))
    end

    test "the only owner cannot leave", %{conn: conn, owner: owner, ws: ws} do
      {:ok, view, _html} = open(conn, owner, ws)

      assert has_element?(view, ~s(#leave-workspace[aria-disabled="true"]))
      assert render(view) =~ "你是唯一的所有者，请先把其他成员设为所有者"

      render_click(view, "ask_leave", %{})
      refute open?(view, "leave-dialog")
    end

    test "with two owners the button is enabled", %{
      conn: conn,
      owner: owner,
      admin: admin,
      ws: ws
    } do
      {:ok, _} =
        Members.change_role(workspace_scope_fixture(owner, ws), membership_id(ws, admin), :owner)

      {:ok, view, _html} = open(conn, owner, ws)
      refute has_element?(view, ~s(#leave-workspace[aria-disabled]))
    end

    test "the server still refuses the last owner",
         %{conn: conn, owner: owner, admin: admin, ws: ws} do
      {:ok, _} =
        Members.change_role(workspace_scope_fixture(owner, ws), membership_id(ws, admin), :owner)

      {:ok, view, _html} = open(conn, owner, ws)
      view |> element("#leave-workspace") |> render_click()

      # The other owner steps down meanwhile.
      {:ok, _} =
        Members.change_role(workspace_scope_fixture(admin, ws), membership_id(ws, admin), :admin)

      html = render_click(view, "leave", %{})
      assert html =~ "工作区至少需要一个所有者"
      assert Workspaces.get_membership(ws.id, owner.id).role == :owner
    end
  end

  defp membership_id(ws, user), do: Workspaces.get_membership(ws.id, user.id).id
end

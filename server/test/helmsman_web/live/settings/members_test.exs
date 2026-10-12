defmodule HelmsmanWeb.SettingsLive.MembersTest do
  @moduledoc "Spec web-workspace-settings 成员列表页 … 成员页实时刷新."
  use HelmsmanWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, Invitations, Members, Repo, Workspaces}

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

    %{conn: conn, ws: ws, users: users, path: "/w/#{ws.slug}/settings/members"}
  end

  defp open(ctx, role, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[role]), path || ctx.path)

  defp mid(ctx, role), do: Workspaces.get_membership(ctx.ws.id, ctx.users[role].id).id
  defp scope(ctx, role), do: workspace_scope_fixture(ctx.users[role], ctx.ws)
  defp row(ctx, role), do: "#member-#{mid(ctx, role)}"

  describe "member list" do
    test "a viewer sees every member read-only", ctx do
      {:ok, view, _html} = open(ctx, :viewer)

      for {role, label} <- [owner: "所有者", admin: "管理员", member: "成员", viewer: "只读"] do
        assert has_element?(view, "#{row(ctx, role)} [data-role]", label)
      end

      refute has_element?(view, "#invite-button")
      refute has_element?(view, ~s([id$="-role-trigger"]))
      refute has_element?(view, ~s([id$="-actions-trigger"]))
      refute has_element?(view, "#invitations-section")
    end

    test "columns and order", ctx do
      {:ok, view, html} = open(ctx, :member)
      carol = ctx.users.member

      assert has_element?(view, "#{row(ctx, :member)} [data-name]", "carol")
      assert has_element?(view, "#{row(ctx, :member)} [data-self]", "你")
      refute has_element?(view, "#{row(ctx, :admin)} [data-self]")
      assert has_element?(view, "#{row(ctx, :member)} [data-email]", carol.email)
      assert has_element?(view, "#{row(ctx, :member)} [data-actor]")
      assert has_element?(view, "#{row(ctx, :member)} time", "刚刚")

      positions = for role <- [:owner, :admin, :member, :viewer], do: index(html, row(ctx, role))
      assert positions == Enum.sort(positions)
    end
  end

  defp index(html, "#" <> id) do
    {at, _} = :binary.match(html, ~s(id="#{id}"))
    at
  end

  describe "roles" do
    test "an owner makes an admin owner", ctx do
      {:ok, view, _html} = open(ctx, :owner)

      html = view |> element("#member-#{mid(ctx, :admin)}-role-owner") |> render_click()

      assert html =~ "已修改 bob 的角色"
      assert has_element?(view, "#{row(ctx, :admin)} [data-role]", "所有者")
    end

    test "an admin cannot touch the owner row", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, "#member-#{mid(ctx, :owner)}-role-trigger")
      refute has_element?(view, "#member-#{mid(ctx, :owner)}-actions-trigger")
      assert has_element?(view, "#{row(ctx, :owner)} [data-role]", "所有者")
    end

    test "an admin's role menu has no owner", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      carol = mid(ctx, :member)

      assert has_element?(view, "#member-#{carol}-role-trigger")
      refute has_element?(view, "#member-#{carol}-role-owner")

      for role <- ~w(admin member viewer),
          do: assert(has_element?(view, "#member-#{carol}-role-#{role}"))

      assert has_element?(view, ~s(#member-#{carol}-role-member[aria-checked="true"]))
    end

    test "the only owner cannot step down", ctx do
      {:ok, view, _html} = open(ctx, :owner)
      me = mid(ctx, :owner)

      for role <- ~w(admin member viewer) do
        assert has_element?(view, ~s(#member-#{me}-role-#{role}[aria-disabled="true"]))
        assert has_element?(view, "#member-#{me}-role-#{role}-reason", "工作区至少需要一个所有者")
      end
    end

    test "an admin lowering their own role confirms first", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      me = mid(ctx, :admin)

      view |> element("#member-#{me}-role-member") |> render_click()
      assert in_portal?(view, "members-confirm", "#members-confirm-description", "降低自己的角色后无法自行恢复")
      assert Workspaces.get_membership(ctx.ws.id, ctx.users.admin.id).role == :admin

      render_click(view, "confirm_role", %{"id" => me, "role" => "member"})
      assert Workspaces.get_membership(ctx.ws.id, ctx.users.admin.id).role == :member

      assert_redirect(view, ctx.path)
      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, ~s([id$="-role-trigger"]))
      refute has_element?(view, "#invite-button")
    end

    test "a refused change is reported and the table reloads", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      # Demoted without a broadcast, so the page still shows the admin controls.
      Workspaces.get_membership(ctx.ws.id, ctx.users.admin.id)
      |> Ecto.Changeset.change(role: :member)
      |> Repo.update!()

      html = render_click(view, "change_role", %{"id" => mid(ctx, :member), "role" => "viewer"})
      assert html =~ "没有权限执行此操作"
      assert has_element?(view, "#{row(ctx, :member)} [data-role]", "成员")
      assert has_element?(view, "#{row(ctx, :admin)} [data-role]", "成员")
    end
  end

  describe "removing" do
    test "an admin removes a member", ctx do
      carol = ctx.users.member
      Phoenix.PubSub.subscribe(Helmsman.PubSub, "user:#{carol.id}")
      {:ok, view, _html} = open(ctx, :admin)
      id = mid(ctx, :member)

      view |> element("#member-#{id}-remove") |> render_click()
      assert in_portal?(view, "members-confirm", "#members-confirm-title", "移除 carol？")
      assert in_portal?(view, "members-confirm", "#members-confirm-description", "Token 将被吊销")

      html = render_click(view, "remove", %{"id" => id})
      assert html =~ "已移除 carol"
      refute has_element?(view, "#member-#{id}")

      ws_id = ctx.ws.id
      assert_receive {:membership_changed, ^ws_id, :removed}
    end

    test "no removal on one's own row", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, "#member-#{mid(ctx, :admin)}-actions-trigger")
      assert has_element?(view, "#member-#{mid(ctx, :member)}-actions-trigger")
    end
  end

  describe "inviting" do
    test "a generic link", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      view |> element("#invite-button") |> render_click()
      assert_patch(view, ctx.path <> "?panel=invite")
      assert open?(view, "invite-panel")
      assert in_portal?(view, "invite-panel", "#invite-generic-warning", "任何拿到链接的人")

      render_submit(view, "invite", %{"invite" => %{"email" => "", "role" => "member"}})

      link = portal_text(view, "invite-panel", "#invite-link-value") |> String.trim()
      assert link =~ ~r{^http.*/invite/[A-Za-z0-9_-]+$}
      assert in_portal?(view, "invite-panel", "#invite-link-copy")
      [_, token] = Regex.run(~r{/invite/(.+)$}, link)
      assert {:ok, %{role: :member}} = Invitations.preview(token)

      render_patch(view, ctx.path)
      refute open?(view, "invite-panel")
      assert has_element?(view, "#invitations [data-target]", "通用链接")
      assert has_element?(view, "#invitations [data-role]", "成员")
    end

    test "a link bound to an email is mailed", ctx do
      {:ok, view, _html} = open(ctx, :admin, ctx.path <> "?panel=invite")
      assert open?(view, "invite-panel")

      render_submit(view, "invite", %{"invite" => %{"email" => "bob@x.com", "role" => "viewer"}})

      assert in_portal?(view, "invite-panel", "#invite-link-value", "/invite/")
      assert in_portal?(view, "invite-panel", "#invite-email-sent", "已向 bob@x.com 发送邀请邮件")
      assert_receive {:email, %Swoosh.Email{to: [{_, "bob@x.com"}]}}
    end

    test "the link is gone after a reload", ctx do
      url = ctx.path <> "?panel=invite"
      {:ok, view, _html} = open(ctx, :admin, url)
      render_submit(view, "invite", %{"invite" => %{"email" => "", "role" => "member"}})
      link = portal_text(view, "invite-panel", "#invite-link-value") |> String.trim()

      {:ok, view, html} = open(ctx, :admin, url)
      refute html =~ link
      refute in_portal?(view, "invite-panel", "#invite-result")
      assert has_element?(view, "#invitations [data-target]", "通用链接")
    end

    test "an admin can grant admin, member and viewer", ctx do
      {:ok, view, _html} = open(ctx, :admin, ctx.path <> "?panel=invite")

      options =
        portal(view, "invite-panel") |> LazyHTML.query("#invite-role option") |> LazyHTML.text()

      assert options == "管理员成员只读"

      assert portal_attr(view, "invite-panel", "#invite-role option[selected]", "value") ==
               "member"
    end

    test "invalid input keeps the panel open", ctx do
      {:ok, view, _html} = open(ctx, :admin, ctx.path <> "?panel=invite")
      render_submit(view, "invite", %{"invite" => %{"email" => "nope", "role" => "viewer"}})

      assert open?(view, "invite-panel")
      assert in_portal?(view, "invite-panel", "[role=alert]")
      assert in_portal?(view, "invite-panel", "#invite-email-error")
      assert portal_attr(view, "invite-panel", "#invite-email", "value") == "nope"
    end

    test "members cannot open the panel", ctx do
      {:ok, view, _html} = open(ctx, :member, ctx.path <> "?panel=invite")
      refute open?(view, "invite-panel")
    end
  end

  describe "pending invitations" do
    test "revoking", ctx do
      %{token: token} = invitation_fixture(scope(ctx, :admin), %{email: "bob@x.com"})
      {:ok, view, _html} = open(ctx, :admin)
      [pending] = elem(Invitations.list_pending(scope(ctx, :admin)), 1)

      assert has_element?(view, "#invitation-#{pending.id} [data-target]", "bob@x.com")
      view |> element("#invitation-#{pending.id}-revoke") |> render_click()
      assert in_portal?(view, "members-confirm", "#members-confirm-title", "撤销邀请？")

      html = render_click(view, "revoke", %{"id" => pending.id})
      assert html =~ "邀请已撤销"
      refute has_element?(view, "#invitation-#{pending.id}")
      assert {:error, :invalid_invitation} = Invitations.preview(token)
    end

    test "an admin cannot revoke an owner invitation", ctx do
      invitation_fixture(scope(ctx, :owner), %{role: :owner})
      {:ok, view, _html} = open(ctx, :admin)
      [pending] = elem(Invitations.list_pending(scope(ctx, :admin)), 1)

      assert has_element?(view, "#invitation-#{pending.id} [data-role]", "所有者")
      refute has_element?(view, "#invitation-#{pending.id}-revoke")
    end

    test "empty state", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      assert has_element?(view, "#invitations-empty", "没有待接受的邀请")
    end
  end

  describe "live updates" do
    test "someone accepting an invitation shows up", ctx do
      %{token: token, invitation: invitation} = invitation_fixture(scope(ctx, :admin))
      {:ok, view, _html} = open(ctx, :admin)
      pid = view.pid
      assert has_element?(view, "#invitation-#{invitation.id}")

      erin = user_fixture(%{display_name: "erin"})
      {:ok, _} = Invitations.accept(erin, token)

      assert has_element?(view, "#members [data-name]", "erin")
      refute has_element?(view, "#invitation-#{invitation.id}")
      assert has_element?(view, "#invitations-empty")
      assert view.pid == pid
    end

    test "another admin's role change shows up", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      {:ok, _} = Members.change_role(scope(ctx, :owner), mid(ctx, :member), :viewer)
      assert has_element?(view, "#{row(ctx, :member)} [data-role]", "只读")
    end
  end

  describe "workspace topic messages (D8)" do
    defp broadcast(ctx, message),
      do: Phoenix.PubSub.broadcast(Helmsman.PubSub, Events.topic(:workspace, ctx.ws.id), message)

    test "unhandled messages are ignored, handled ones still work", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      log =
        capture_log(fn ->
          broadcast(ctx, {:projects_changed})
          broadcast(ctx, {:unknown_event, 1})
          render(view)
        end)

      assert Process.alive?(view.pid)
      refute log =~ "error"
      refute log =~ "undefined handle_info"

      # A change without a broadcast, then {:members_changed} reloads it.
      Workspaces.get_membership(ctx.ws.id, ctx.users.member.id)
      |> Ecto.Changeset.change(role: :viewer)
      |> Repo.update!()

      broadcast(ctx, {:members_changed})
      assert has_element?(view, "#{row(ctx, :member)} [data-role]", "只读")

      broadcast(ctx, {:workspace_updated, %{id: ctx.ws.id, name: "Acme 中国", slug: ctx.ws.slug}})
      assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme 中国")

      {:ok, _} = Members.remove(scope(ctx, :owner), mid(ctx, :admin))
      {path, flash} = assert_redirect(view)
      assert path == "/"
      assert flash["error"] =~ "你已被移出"
    end
  end
end

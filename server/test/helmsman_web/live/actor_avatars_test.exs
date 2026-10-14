defmodule HelmsmanWeb.ActorAvatarsLiveTest do
  @moduledoc """
  web-avatars 个人头像 / Agent 与小队的头像 / 头像的实时刷新 and web-components
  「Actor 标识」「执行方菜单与页面一致」 on the workspace pages (add-actor-avatars D7,
  D11, D15), against `Helmsman.Avatars` and its notifications.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Avatars, AvatarsFixtures, Repo, Squads}
  alias HelmsmanWeb.Components.Actor, as: ActorComponents
  alias HelmsmanWeb.TaskLive.Show

  @webp AvatarsFixtures.webp(64, 64)
  @webp2 AvatarsFixtures.png(48, 48)

  # Reads of the appearance table (the one query joining actors with avatars) made by
  # the LiveView process `pid`, counted while `fun` runs.
  defp appearance_reads(pid, fun) do
    test = self()
    ref = make_ref()
    handler = "appearance-reads-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == pid and meta.source == "actors" and meta.query =~ ~s("avatars"),
          do: send(test, {ref, :read})
      end,
      nil
    )

    try do
      fun.()
      count(ref, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count(ref, n) do
    receive do
      {^ref, :read} -> count(ref, n + 1)
    after
      0 -> n
    end
  end

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    bob = user_fixture(%{display_name: "bob"})
    carol = user_fixture(%{display_name: "carol"})
    dave = user_fixture(%{display_name: "dave"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, bob, :member)
    member_fixture(ws, carol, :admin)
    member_fixture(ws, dave, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)

    managed_agent_fixture(alice_scope, %{name: "keel/dev", access: "workspace"})

    managed_agent_fixture(alice_scope, %{
      name: "keel/review",
      access: "workspace",
      provider: "codex"
    })

    {:ok, _squad} =
      Squads.create(alice_scope, %{name: "backend-team", leader: "keel/dev", members: []})

    project = project_fixture(workspace_scope_fixture(olga, ws), %{key: "BOS"})
    task = task_fixture(alice_scope, project.key, %{title: "Avatars", assignee: "keel/dev"})

    %{
      conn: conn,
      ws: ws,
      users: %{olga: olga, alice: alice, bob: bob, carol: carol, dave: dave},
      alice_scope: alice_scope,
      carol_scope: workspace_scope_fixture(carol, ws),
      task: task,
      name: fn user -> Repo.get_by!(Actor, workspace_id: ws.id, user_id: user.id).name end
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)
  defp task_path(ctx), do: "/w/#{ctx.ws.slug}/t/#{ctx.task.ident}"
  defp avatar_prefix(ctx), do: "/w/#{ctx.ws.slug}/avatars/"

  describe "marks on the task pages" do
    test "the assignee shows its CLI on the task list and the task page", ctx do
      {:ok, list, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/p/BOS")

      assert has_element?(
               list,
               "#task-#{ctx.task.ident} [data-actor-kind=agent] [data-brand=claude]"
             )

      {:ok, show, _} = open(ctx, :bob, task_path(ctx))
      assert has_element?(show, "#task-assignee [data-actor-kind=agent] [data-brand=claude]")
      assert has_element?(show, "#task-assignee .hm-tooltip", "托管 · Claude Code")
    end

    test "the assignee menu shows the same marks as the pages", ctx do
      {:ok, view, _} = open(ctx, :alice, task_path(ctx))
      alice = ctx.name.(ctx.users.alice)
      tint = ActorComponents.tint_index(alice)

      review = Show.assignee_item_id("keel/review")
      squad = Show.assignee_item_id("backend-team")
      me = Show.assignee_item_id(alice)

      assert has_element?(view, "##{review} [data-actor-mark=agent] [data-brand=codex]")
      assert has_element?(view, "##{squad} [data-actor-mark=squad] .lucide-users")
      assert has_element?(view, "##{me} [data-actor-mark=human] [data-tint='#{tint}']")
    end
  end

  describe "live refresh" do
    test "another tab's upload shows on the task page and the task list without a reload",
         ctx do
      {:ok, show, _} = open(ctx, :bob, task_path(ctx))
      {:ok, list, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/p/BOS")
      refute has_element?(show, "#task-assignee img[data-avatar]")

      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, @webp)

      assert has_element?(
               show,
               "#task-assignee img[data-avatar][src='#{avatar_prefix(ctx)}#{key}']"
             )

      eventually(fn ->
        has_element?(list, "#task-#{ctx.task.ident} img[data-avatar][src$='#{key}']")
      end)
    end

    test "an avatar change and an Agent change each read the appearance once", ctx do
      {:ok, view, _} = open(ctx, :bob, task_path(ctx))
      topic = Helmsman.Events.topic(:workspace, ctx.ws.id)

      assert appearance_reads(view.pid, fn ->
               Helmsman.Events.broadcast(topic, {:avatars_changed})
               render(view)
             end) == 1

      assert appearance_reads(view.pid, fn ->
               Helmsman.Events.broadcast(topic, {:agents_changed})
               render(view)
             end) == 1

      # A real upload: one notification, one read.
      assert appearance_reads(view.pid, fn ->
               {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, @webp)
               render(view)
             end) == 1
    end

    test "a renamed squad keeps its avatar on the task page", ctx do
      {:ok, _} =
        Helmsman.Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "backend-team"})

      {:ok, %{key: key}} = Avatars.put(ctx.carol_scope, {:actor, "backend-team"}, @webp2)

      {:ok, view, _} = open(ctx, :bob, task_path(ctx))
      assert has_element?(view, "#task-assignee", "backend-team")
      assert has_element?(view, "#task-assignee img[src$='#{key}']")

      {:ok, _} = Squads.update(ctx.carol_scope, "backend-team", %{name: "platform-team"})

      assert has_element?(view, "#task-assignee", "platform-team")
      assert has_element?(view, "#task-assignee img[data-avatar][src$='#{key}']")
    end

    test "the squad pages subscribe to the squad topic once (through the shell)", ctx do
      topic = Squads.topic(ctx.ws.id)

      for path <- ["/w/#{ctx.ws.slug}/squads", "/w/#{ctx.ws.slug}/squads/backend-team"] do
        {:ok, view, _} = open(ctx, :alice, path)

        count =
          Helmsman.PubSub
          |> Registry.lookup(topic)
          |> Enum.count(fn {pid, _} -> pid == view.pid end)

        assert count == 1
      end
    end

    test "the user menu follows the user's avatar", ctx do
      {:ok, view, _} = open(ctx, :bob, task_path(ctx))
      refute has_element?(view, "#hm-user-menu-trigger img[data-avatar]")

      bob_scope = workspace_scope_fixture(ctx.users.bob, ctx.ws)
      {:ok, %{key: key}} = Avatars.put(bob_scope, :me, @webp)

      assert has_element?(
               view,
               "#hm-user-menu-trigger img[data-avatar][src='/users/avatar/#{key}']"
             )
    end

    test "a viewer's own avatar shows on their identity in the workspace", ctx do
      dave_scope = workspace_scope_fixture(ctx.users.dave, ctx.ws)
      {:ok, view, _} = open(ctx, :olga, "/w/#{ctx.ws.slug}/settings/members")
      refute has_element?(view, "#members img[data-avatar]")

      {:ok, %{key: key}} = Avatars.put(dave_scope, :me, @webp)

      assert has_element?(view, "#members img[data-avatar][src='#{avatar_prefix(ctx)}#{key}']")
    end
  end

  describe "query page" do
    test "every row shown is refreshed, beyond the first 200 (code-review-2)", ctx do
      for _ <- 1..200, do: task_fixture(ctx.alice_scope, "BOS", %{assignee: "keel/dev"})
      {:ok, view, _} = open(ctx, :alice, "/w/#{ctx.ws.slug}/query")
      view |> form("#query-form", query: %{bql: "project = BOS"}) |> render_submit()
      for _ <- 1..4, do: view |> element("#query-tasks-more") |> render_click()

      rows = fn selector ->
        view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
      end

      assert rows.("#query-tasks tr[id^=query-task-]") == 201

      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, @webp)
      send(view.pid, :reload_rows)
      assert rows.("#query-tasks img[data-avatar][src$='#{key}']") == 201
      assert rows.("#query-tasks tr[id^=query-task-]") == 201
    end
  end

  describe "Agent page" do
    defp agent_path(ctx), do: "/w/#{ctx.ws.slug}/agents/keel/dev"

    test "the owner gets the 更换头像 menu with 上传图片…", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(view, "#agent-avatar-menu-trigger[aria-label='更换头像']")
      assert has_element?(view, "#agent-avatar-upload-item")
      refute has_element?(view, "#agent-avatar-remove-item")
      assert has_element?(view, "#agent-avatar [data-actor-mark=agent].size-10")
    end

    test "the account row shows the account's icon, the port included (D19)", ctx do
      local =
        provider_account_fixture(ctx.users.alice, %{
          name: "local",
          base_url: "http://localhost:11434/v1"
        })

      chosen =
        provider_account_fixture(ctx.users.alice, %{
          name: "proxy",
          base_url: "https://my-proxy.example.com/v1",
          icon: "openrouter"
        })

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: local.id})
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(view, "[data-provider-account-row] [data-account-icon=ollama]")

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: chosen.id})
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(view, "[data-provider-account-row] [data-account-icon=openrouter]")
    end

    test "another member sees the mark only, neither clickable nor focusable", ctx do
      {:ok, view, _} = open(ctx, :bob, agent_path(ctx))
      refute has_element?(view, "#agent-avatar-menu-trigger")
      refute has_element?(view, "#agent-avatar button")
      refute has_element?(view, "#agent-avatar [tabindex='0']")
      assert has_element?(view, "#agent-avatar [data-actor-mark=agent]")
    end

    test "an admin may only remove someone else's avatar", ctx do
      {:ok, view, _} = open(ctx, :carol, agent_path(ctx))
      refute has_element?(view, "#agent-avatar-menu-trigger")

      Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, @webp)
      assert has_element?(view, "#agent-avatar-menu-trigger")
      assert has_element?(view, "#agent-avatar-remove-item")
      refute has_element?(view, "#agent-avatar-upload-item")

      view |> element("#agent-avatar-remove-item") |> render_click()
      assert in_portal?(view, "agent-avatar-remove", "#agent-avatar-remove-cancel[autofocus]")
      render_click(with_target(view, "#agent-avatar"), "remove", %{})

      refute has_element?(view, "#agent-avatar img[data-avatar]")
      assert render(view) =~ "已恢复缺省头像"
    end

    test "the owner uploads through the dialog", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      view |> element("#agent-avatar-upload-item") |> render_click()
      render_hook(with_target(view, "#agent-avatar"), "source", %{})
      nonce = portal_attr(view, "agent-avatar-dialog", "#agent-avatar-cropper", "data-nonce")

      view
      |> file_input("#agent-avatar-upload", :avatar, [
        %{name: "avatar-#{nonce}.webp", content: @webp, type: "image/webp"}
      ])
      |> render_upload("avatar-#{nonce}.webp")

      assert has_element?(view, "#agent-avatar img[data-avatar][src^='#{avatar_prefix(ctx)}']")
      assert render(view) =~ "头像已更新"
    end
  end

  describe "squad page" do
    defp squad_path(ctx), do: "/w/#{ctx.ws.slug}/squads/backend-team"

    test "the leader's owner and admins may set it, other members only see it", ctx do
      {:ok, alice, _} = open(ctx, :alice, squad_path(ctx))
      assert has_element?(alice, "#squad-avatar-upload-item")

      {:ok, carol, _} = open(ctx, :carol, squad_path(ctx))
      assert has_element?(carol, "#squad-avatar-upload-item")

      {:ok, bob, _} = open(ctx, :bob, squad_path(ctx))
      refute has_element?(bob, "#squad-avatar-menu-trigger")
      assert has_element?(bob, "#squad-avatar [data-actor-mark=squad]")
    end
  end
end

defmodule HelmsmanWeb.AvatarEditorIconsTest do
  @moduledoc """
  update-actor-icons D4, D11–D13 on the workspace and account pages: web-avatars
  「选择内置图标」, the new scenarios of 「Agent 与小队的头像」「移除头像」「个人头像」
  「头像的实时刷新」, and web-components 「CLI 位置不变」.

  Against `Helmsman.Avatars` and `Helmsman.Actors.appearance/1`; a runtime's vendor is
  reported through a real `Helmsman.Daemons.register/3`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Avatars, AvatarsFixtures, Daemons, Events, Repo, Squads}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias HelmsmanProtocol.{CLI, Machine, Report}

  @webp AvatarsFixtures.webp(64, 64)

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
    task = task_fixture(alice_scope, project.key, %{title: "Icons", assignee: "keel/dev"})

    %{
      conn: conn,
      ws: ws,
      users: %{olga: olga, alice: alice, bob: bob, carol: carol, dave: dave},
      alice_scope: alice_scope,
      task: task
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)
  defp agent_path(ctx, name \\ "keel/dev"), do: "/w/#{ctx.ws.slug}/agents/#{name}"

  # The daemon of `name`'s runtime reports its Claude Code with `vendor` (D10), the way
  # a `sync` does.
  defp report_vendor(ctx, name, vendor) do
    actor = Repo.get_by!(Actor, workspace_id: ctx.ws.id, name: name)
    runtime = Repo.get!(Runtime, Repo.get_by!(AgentProfile, actor_id: actor.id).runtime_id)
    daemon = Repo.get!(Daemon, runtime.daemon_id)

    cli = %CLI{
      provider: :claude,
      version: "3.2.1",
      models: [],
      efforts: [],
      available: true,
      vendor: vendor
    }

    report = %Report.Sync{
      machine: %Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"},
      clis: [cli],
      max_concurrency: 2
    }

    {:ok, _} = Daemons.register(daemon.id, daemon.auth_epoch, report)
  end

  # Reads of the appearance table (the query joining actors with avatars) by `pid`.
  defp appearance_reads(pid, fun) do
    test = self()
    ref = make_ref()
    handler = "icon-appearance-reads-#{inspect(ref)}"

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

  defp editor(view, id), do: with_target(view, "##{id}")

  defp dialog?(view, id, selector, text \\ nil),
    do: in_portal?(view, "#{id}-dialog", selector, text)

  defp open_icons(view, id) do
    view |> element("##{id}-icon-item") |> render_click()
    assert open?(view, "#{id}-dialog")
    view
  end

  defp search(view, id, q), do: render_change(editor(view, id), "icons", %{"q" => q})

  defp shown_icons(view, id) do
    view
    |> portal("#{id}-dialog")
    |> LazyHTML.query("##{id}-icons label[data-icon]")
    |> LazyHTML.attribute("data-icon")
  end

  defp group_icons(view, id, group) do
    view
    |> portal("#{id}-dialog")
    |> LazyHTML.query("##{id}-icons-#{group} label[data-icon]")
    |> LazyHTML.attribute("data-icon")
  end

  describe "选择内置图标" do
    test "搜索并选择: the list narrows, saving closes the dialog and shows the icon", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      assert dialog?(view, "agent-avatar", "#agent-avatar-tab-icon[aria-selected=true]")
      assert dialog?(view, "agent-avatar", "#agent-avatar-panel-image[hidden]")
      assert length(shown_icons(view, "agent-avatar")) == 49

      search(view, "agent-avatar", "z")
      icons = shown_icons(view, "agent-avatar")
      assert "zai" in icons
      refute "openai" in icons

      for icon <- icons do
        %{name: name} =
          HelmsmanWeb.Brands.icon_groups()
          |> Enum.flat_map(&elem(&1, 1))
          |> Enum.find(&(&1.icon == icon))

        assert String.contains?(String.downcase(name), "z") or String.contains?(icon, "z")
      end

      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-save[disabled]")
      render_change(editor(view, "agent-avatar"), "icons", %{"q" => "z", "icon" => "zai"})
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-zai.border-brand input[checked]")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-preview [data-brand=zai].size-10")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-preview [data-brand=zai].size-5")
      refute dialog?(view, "agent-avatar", "#agent-avatar-icon-save[disabled]")

      render_submit(editor(view, "agent-avatar"), "save_icon", %{"icon" => "zai"})

      refute open?(view, "agent-avatar-dialog")
      assert render(view) =~ "头像已更新"
      assert has_element?(view, "#agent-avatar [data-mark=icon] [data-brand=zai]")
    end

    test "按 CLI 键搜索: copilot finds GitHub Copilot in the CLI group", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      search(view, "agent-avatar", "  COPILOT ")
      assert group_icons(view, "agent-avatar", "cli") == ["githubcopilot"]
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-githubcopilot", "GitHub Copilot")
      refute dialog?(view, "agent-avatar", "#agent-avatar-icons-vendor")
    end

    test "three groups in order, each a fieldset with a legend, ordered by name", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      tree = portal(view, "agent-avatar-dialog")

      assert tree
             |> LazyHTML.query("fieldset legend")
             |> Enum.map(&LazyHTML.text/1)
             |> Enum.map(&String.trim/1) ==
               ["CLI", "模型厂商", "平台网关"]

      assert length(group_icons(view, "agent-avatar", "cli")) == 12
      assert length(group_icons(view, "agent-avatar", "vendor")) == 27
      assert length(group_icons(view, "agent-avatar", "platform")) == 10

      names =
        tree
        |> LazyHTML.query("#agent-avatar-icons-cli label span.line-clamp-2")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert names == Enum.sort(names)
      # An Agent previews in a rounded square.
      assert in_portal?(
               view,
               "agent-avatar-dialog",
               "#agent-avatar-icon-zai [data-actor-mark=agent].size-7"
             )
    end

    test "只用键盘: one radio group in one form, saved by its submit button", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      tree = portal(view, "agent-avatar-dialog")

      radios = LazyHTML.query(tree, "#agent-avatar-icons input[type=radio]")
      assert Enum.count(radios) == 49
      assert radios |> LazyHTML.attribute("name") |> Enum.uniq() == ["icon"]

      assert in_portal?(
               view,
               "agent-avatar-dialog",
               "#agent-avatar-icons button#agent-avatar-icon-save[type=submit]"
             )

      assert in_portal?(
               view,
               "agent-avatar-dialog",
               "#agent-avatar-icon-search[aria-label='搜索图标'][phx-debounce='150']"
             )

      # Arrow keys move the checked radio (the browser sends the change), Enter submits
      # the form with the checked radio.
      render_change(editor(view, "agent-avatar"), "icons", %{"q" => "", "icon" => "cline"})
      render_change(editor(view, "agent-avatar"), "icons", %{"q" => "", "icon" => "codebuddy"})

      render_submit(editor(view, "agent-avatar"), "save_icon", %{"q" => "", "icon" => "codebuddy"})

      assert has_element?(view, "#agent-avatar [data-brand=codebuddy]")
    end

    test "a selection filtered out by the search stays selected and previewed", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      render_change(editor(view, "agent-avatar"), "icons", %{"q" => "", "icon" => "kimi"})
      search(view, "agent-avatar", "openai")
      refute "kimi" in shown_icons(view, "agent-avatar")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-preview [data-brand=kimi]")

      render_submit(editor(view, "agent-avatar"), "save_icon", %{"q" => "openai"})
      assert has_element?(view, "#agent-avatar [data-brand=kimi]")
    end

    test "没有匹配", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      search(view, "agent-avatar", "qqqq")
      refute dialog?(view, "agent-avatar", "fieldset")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icons-empty", "没有匹配的图标")
    end

    test "the current icon is preselected; saving needs a different one", ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "qwen")
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-qwen input[checked]")
      assert dialog?(view, "agent-avatar", "#agent-avatar-icon-save[disabled]")

      # Re-saving the current icon is a no-op even when forced.
      render_submit(editor(view, "agent-avatar"), "save_icon", %{"icon" => "qwen"})
      assert open?(view, "agent-avatar-dialog")
    end

    test "unknown_icon shows 这个图标不可用 at the top and keeps the dialog open", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      render_submit(editor(view, "agent-avatar"), "save_icon", %{"icon" => "foo"})
      assert open?(view, "agent-avatar-dialog")
      assert dialog?(view, "agent-avatar", "#agent-avatar-error[role=alert]", "这个图标不可用")
      assert has_element?(view, "#agent-avatar [data-mark=cli]")
    end

    test "a refusal after the rights changed uses the existing message", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")

      Repo.update_all(
        from(a in Actor, where: a.workspace_id == ^ctx.ws.id and a.name == "keel/dev"),
        set: [owner_id: ctx.users.bob.id]
      )

      render_submit(editor(view, "agent-avatar"), "save_icon", %{"icon" => "zai"})
      assert dialog?(view, "agent-avatar", "#agent-avatar-error", "你没有权限修改这个头像")
    end
  end

  describe "tabs and stale uploads (D12)" do
    defp nonce(view),
      do: portal_attr(view, "agent-avatar-dialog", "#agent-avatar-cropper", "data-nonce")

    defp upload(view, name),
      do:
        file_input(view, "#agent-avatar-upload", :avatar, [
          %{name: name, content: @webp, type: "image/webp"}
        ])

    defp writes(n \\ 0) do
      receive do
        {:avatars_changed} -> writes(n + 1)
      after
        100 -> n
      end
    end

    test "切换标签页取消上传: the icon wins, the old upload is dropped", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.ws.id))
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      view |> element("#agent-avatar-upload-item") |> render_click()
      assert dialog?(view, "agent-avatar", "#agent-avatar-tab-image[aria-selected=true]")
      assert dialog?(view, "agent-avatar", "#agent-avatar-panel-icon[hidden]")
      render_hook(editor(view, "agent-avatar"), "source", %{})
      old = nonce(view)
      stale = upload(view, "avatar-#{old}.webp")
      render_upload(stale, "avatar-#{old}.webp", 50)

      render_click(editor(view, "agent-avatar"), "tab", %{"tab" => "icon"})
      assert nonce(view) != old
      assert dialog?(view, "agent-avatar", "#agent-avatar-panel-image[hidden]")
      render_change(editor(view, "agent-avatar"), "icons", %{"q" => "", "icon" => "openai"})
      render_submit(editor(view, "agent-avatar"), "save_icon", %{"icon" => "openai"})
      assert writes() == 1

      catch_exit(render_upload(stale, "avatar-#{old}.webp", 50))
      assert writes() == 0
      assert has_element?(view, "#agent-avatar [data-brand=openai]")
      refute has_element?(view, "#agent-avatar img[data-avatar]")
    end

    test "an upload completing while the icon tab is shown is consumed and dropped", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.ws.id))
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      view |> element("#agent-avatar-upload-item") |> render_click()
      render_hook(editor(view, "agent-avatar"), "source", %{})
      render_click(editor(view, "agent-avatar"), "tab", %{"tab" => "icon"})

      # Even named with the dialog's current nonce: @avatar_tab is :icon.
      current = nonce(view)
      render_upload(upload(view, "avatar-#{current}.webp"), "avatar-#{current}.webp")
      assert writes() == 0
      assert open?(view, "agent-avatar-dialog")
      refute has_element?(view, "#agent-avatar img[data-avatar]")
    end

    test "back on the image tab, the renewed nonce saves normally", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      view |> element("#agent-avatar-icon-item") |> render_click()
      render_click(editor(view, "agent-avatar"), "tab", %{"tab" => "image"})
      render_hook(editor(view, "agent-avatar"), "source", %{})
      current = nonce(view)
      render_upload(upload(view, "avatar-#{current}.webp"), "avatar-#{current}.webp")
      assert has_element?(view, "#agent-avatar img[data-avatar]")
    end
  end

  describe "menu (Agent 与小队的头像)" do
    test "所属用户: 上传图片… and 选择图标…, 恢复缺省头像 once an icon is set", ctx do
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(view, "#agent-avatar-upload-item", "上传图片…")
      assert has_element?(view, "#agent-avatar-icon-item", "选择图标…")
      refute has_element?(view, "#agent-avatar-remove-item")

      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      assert has_element?(view, "#agent-avatar-remove-item", "恢复缺省头像")
    end

    test "其他 member: the mark only", ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      {:ok, view, _} = open(ctx, :bob, agent_path(ctx))
      refute has_element?(view, "#agent-avatar-menu-trigger")
      assert has_element?(view, "#agent-avatar [data-brand=zai]")
    end

    test "admin 面对有头像的别人的 Agent: only 恢复缺省头像", ctx do
      {:ok, view, _} = open(ctx, :carol, agent_path(ctx))
      refute has_element?(view, "#agent-avatar-menu-trigger")

      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      assert has_element?(view, "#agent-avatar-remove-item")
      refute has_element?(view, "#agent-avatar-upload-item")
      refute has_element?(view, "#agent-avatar-icon-item")

      view |> element("#agent-avatar-remove-item") |> render_click()
      assert in_portal?(view, "agent-avatar-remove", "#agent-avatar-remove-cancel[autofocus]")
      render_click(with_target(view, "#agent-avatar"), "remove", %{})
      assert has_element?(view, "#agent-avatar [data-mark=cli] [data-brand=claude]")
    end

    test "squads: the owner of the leader picks an icon, shown in a rounded square", ctx do
      {:ok, view, _} = open(ctx, :alice, "/w/#{ctx.ws.slug}/squads/backend-team")
      open_icons(view, "squad-avatar")
      assert in_portal?(view, "squad-avatar-dialog", "#squad-avatar-default", "小队图标")
      render_submit(editor(view, "squad-avatar"), "save_icon", %{"icon" => "claude"})

      assert has_element?(
               view,
               "#squad-avatar [data-actor-mark=squad][data-mark=icon] [data-brand=claude].rounded-\\[25\\%\\]"
             )
    end
  end

  describe "缺省说明 and 移除内置图标" do
    defp default_text(view, id),
      do:
        view
        |> portal_text("#{id}-dialog", "##{id}-default > span.text-fg")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

    test "Agent: runtime vendor, account vendor, CLI icon, bot", ctx do
      report_vendor(ctx, "keel/dev", "zai")
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      assert default_text(view, "agent-avatar") == "Z.ai（来自运行时的 Claude Code 配置）"
      assert dialog?(view, "agent-avatar", "#agent-avatar-default", "缺省头像：")
      assert dialog?(view, "agent-avatar", "#agent-avatar-default [data-brand=zai]")
      # On the image tab too.
      render_click(editor(view, "agent-avatar"), "tab", %{"tab" => "image"})
      assert dialog?(view, "agent-avatar", "#agent-avatar-default", "Z.ai（来自运行时的 Claude Code 配置）")

      account =
        provider_account_fixture(ctx.users.alice, %{
          name: "zai",
          base_url: "https://api.z.ai/api/anthropic",
          icon: "zai"
        })

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(view, "agent-avatar")
      assert default_text(view, "agent-avatar") =~ "Z.ai（来自绑定的供应商账号）"

      {:ok, view, _} = open(ctx, :alice, agent_path(ctx, "keel/review"))
      open_icons(view, "agent-avatar")
      assert default_text(view, "agent-avatar") =~ "Codex 图标"
      assert dialog?(view, "agent-avatar", "#agent-avatar-default [data-brand=codex]")

      Repo.insert!(%Actor{
        workspace_id: ctx.ws.id,
        kind: :agent,
        name: "alice/session-1",
        owner_id: ctx.users.alice.id
      })

      {:ok, view, _} = open(ctx, :alice, agent_path(ctx, "alice/session-1"))
      open_icons(view, "agent-avatar")
      assert default_text(view, "agent-avatar") =~ "机器人图标"
    end

    test "账号认不出时不看运行时: the CLI icon", ctx do
      report_vendor(ctx, "keel/dev", "zai")

      account =
        provider_account_fixture(ctx.users.alice, %{
          name: "corp",
          base_url: "https://llm.corp.example"
        })

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})

      {:ok, view, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(view, "#agent-avatar [data-mark=cli] [data-brand=claude]")
      open_icons(view, "agent-avatar")
      assert default_text(view, "agent-avatar") =~ "Claude Code 图标"
    end

    test "移除内置图标: the confirmation names the default, then the Codex icon shows", ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/review"}, "zai")
      {:ok, view, _} = open(ctx, :alice, agent_path(ctx, "keel/review"))
      assert has_element?(view, "#agent-avatar [data-mark=icon] [data-brand=zai]")

      view |> element("#agent-avatar-remove-item") |> render_click()
      assert in_portal?(view, "agent-avatar-remove", "#agent-avatar-remove", "恢复缺省头像？")
      assert in_portal?(view, "agent-avatar-remove", "#agent-avatar-remove-default", "Codex 图标")
      assert in_portal?(view, "agent-avatar-remove", "#agent-avatar-remove-cancel[autofocus]")

      render_click(editor(view, "agent-avatar"), "remove", %{})
      assert render(view) =~ "已恢复缺省头像"
      assert has_element?(view, "#agent-avatar [data-mark=cli] [data-brand=codex]")
      refute has_element?(view, "#agent-avatar-remove-item")
    end
  end

  describe "个人头像" do
    test "选择图标作为个人头像: settings page, the identity and the user menu", ctx do
      {:ok, settings, _} = live(log_in_user(ctx.conn, ctx.users.dave), ~p"/users/settings")
      open_icons(settings, "my-avatar")
      assert in_portal?(settings, "my-avatar-dialog", "#my-avatar-default", "首字母")
      # A person previews in a circle.
      assert in_portal?(
               settings,
               "my-avatar-dialog",
               "#my-avatar-icon-deepseek [data-actor-mark=human].rounded-full"
             )

      render_submit(editor(settings, "my-avatar"), "save_icon", %{"icon" => "deepseek"})
      assert render(settings) =~ "头像已更新"

      assert has_element?(
               settings,
               "#avatar-section [data-mark=icon] [data-brand=deepseek].rounded-full"
             )

      assert has_element?(settings, "#hm-personal-user [data-brand=deepseek]")
      assert has_element?(settings, "#my-avatar-remove-item")

      {:ok, members, _} = open(ctx, :olga, "/w/#{ctx.ws.slug}/settings/members")

      assert has_element?(
               members,
               "#members [data-actor-mark=human][data-mark=icon] [data-brand=deepseek]"
             )

      {:ok, task, _} = open(ctx, :dave, "/w/#{ctx.ws.slug}/t/#{ctx.task.ident}")
      assert has_element?(task, "#hm-user-menu-trigger [data-brand=deepseek]")
    end

    test "the user menu follows a change of the icon without a reload", ctx do
      {:ok, view, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/t/#{ctx.task.ident}")
      refute has_element?(view, "#hm-user-menu-trigger [data-brand]")
      bob = workspace_scope_fixture(ctx.users.bob, ctx.ws)
      {:ok, _} = Avatars.put_icon(bob, :me, "kimi")
      assert has_element?(view, "#hm-user-menu-trigger [data-brand=kimi]")

      {:ok, _} = HelmsmanWeb.AvatarData.put(bob, :me, @webp)
      assert has_element?(view, "#hm-user-menu-trigger img[data-avatar]")
    end
  end

  describe "头像的实时刷新" do
    test "another LiveView picks an icon: the task page updates", ctx do
      {:ok, show, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/t/#{ctx.task.ident}")
      {:ok, list, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/p/BOS")
      {:ok, editor, _} = open(ctx, :alice, agent_path(ctx))
      open_icons(editor, "agent-avatar")
      render_submit(editor(editor, "agent-avatar"), "save_icon", %{"icon" => "zai"})

      assert has_element?(show, "#task-assignee [data-brand=zai]")
      assert has_element?(show, "#task-assignee .hm-tooltip", "图标：Z.ai")
      eventually(fn -> has_element?(list, "#task-#{ctx.task.ident} [data-brand=zai]") end)
    end

    test "运行时厂商变化: identity becomes zai, the CLI column stays claude, one read", ctx do
      {:ok, view, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/agents")
      row = "#agents [data-agent-link] [data-actor-kind=agent]"
      assert has_element?(view, "#{row} [data-mark=cli] [data-brand=claude]")

      reads =
        appearance_reads(view.pid, fn ->
          report_vendor(ctx, "keel/dev", "zai")
          render(view)
        end)

      assert reads == 1

      eventually(fn -> has_element?(view, "#{row} [data-mark=vendor] [data-brand=zai]") end)
      assert has_element?(view, "#agents [data-cli] [data-brand=claude]")
      refute has_element?(view, "#agents [data-cli] [data-brand=zai]")
      assert has_element?(view, "#agents .hm-tooltip", "所属：alice · 托管 · Claude Code · Z.ai")
    end

    test "the task list redraws its rows on a runtime vendor change", ctx do
      {:ok, list, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/p/BOS")
      report_vendor(ctx, "keel/dev", "zai")
      eventually(fn -> has_element?(list, "#task-#{ctx.task.ident} [data-brand=zai]") end)
    end
  end

  describe "CLI 位置不变" do
    test "an account without an icon: the vendor inferred from its host", ctx do
      account =
        provider_account_fixture(ctx.users.alice, %{
          name: "zai-auto",
          base_url: "https://api.z.ai/api/anthropic"
        })

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})

      {:ok, view, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/agents")
      assert has_element?(view, "#agents [data-agent-link] [data-mark=vendor] [data-brand=zai]")
      assert has_element?(view, "#agents [data-cli] [data-brand=claude]")
    end

    test "an Agent bound to a Z.ai account: zai identity, claude in CLI 与机器 and details", ctx do
      account =
        provider_account_fixture(ctx.users.alice, %{
          name: "zai",
          base_url: "https://api.z.ai/api/anthropic",
          icon: "zai"
        })

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})

      {:ok, view, _} = open(ctx, :bob, "/w/#{ctx.ws.slug}/agents")
      assert has_element?(view, "#agents [data-agent-link] [data-mark=vendor] [data-brand=zai]")
      assert has_element?(view, "#agents [data-cli] [data-brand=claude]")

      {:ok, show, _} = open(ctx, :alice, agent_path(ctx))
      assert has_element?(show, "#agent-avatar [data-brand=zai]")
    end
  end
end

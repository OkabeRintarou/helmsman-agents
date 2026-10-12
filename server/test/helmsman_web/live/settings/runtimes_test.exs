defmodule HelmsmanWeb.SettingsLive.RuntimesTest do
  @moduledoc "Spec web-runtimes 运行时页、运行时页实时刷新 (design D7)."
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Daemons, Repo, Runtimes}
  alias Helmsman.Daemons.Daemon
  alias HelmsmanProtocol.{CLI, Machine, Report}

  setup %{conn: conn} do
    _admin = user_fixture()
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    adam = user_fixture(%{display_name: "adam"})
    bob = user_fixture(%{display_name: "bob"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, adam, :admin)
    member_fixture(ws, bob, :member)
    member_fixture(ws, vic, :viewer)

    {mbp, _} =
      daemon_fixture(alice, %{name: "mbp", os: "darwin", arch: "arm64", workspace_ids: [ws.id]})

    claude = runtime_fixture(ws, mbp, %{provider: "claude", models: ["opus", "sonnet"]})

    codex =
      runtime_fixture(ws, mbp, %{
        provider: "codex",
        status: "offline",
        unavailable_reason: "codex 0.1 is too old"
      })

    {bob_box, _} = daemon_fixture(bob, %{name: "bob-box", workspace_ids: [ws.id]})
    bob_rt = runtime_fixture(ws, bob_box, %{provider: "claude"})

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, adam: adam, bob: bob, vic: vic},
      mbp: mbp,
      claude: claude,
      codex: codex,
      bob_rt: bob_rt,
      path: "/w/#{ws.slug}/settings/runtimes"
    }
  end

  defp open(ctx, who, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path || ctx.path)

  defp scope(ctx, who), do: workspace_scope_fixture(ctx.users[who], ctx.ws)

  # Reloads are coalesced for 500ms (HelmsmanWeb.Throttle): poll the page.
  defp eventually(fun, tries \\ 40) do
    if fun.() do
      true
    else
      if tries == 0, do: flunk("condition never held")
      Process.sleep(50)
      eventually(fun, tries - 1)
    end
  end

  describe "content" do
    test "my machines and runtimes, with the reason of an unavailable one", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      assert page_title(view) == "运行时 · Acme"
      assert has_element?(view, "h1", "运行时")
      refute has_element?(view, ~s(nav[aria-label="设置"]))
      assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "运行时")
      refute has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "设置")

      assert has_element?(view, "#daemon-#{ctx.mbp.id} [data-daemon-name]", "mbp")
      assert has_element?(view, ~s(#daemon-#{ctx.mbp.id} [data-presence="online"]))
      assert has_element?(view, "#daemon-#{ctx.mbp.id}", "darwin / arm64")
      assert has_element?(view, "#daemon-#{ctx.mbp.id} [data-daemon-workspaces]", "Acme")

      assert has_element?(view, ~s(#runtime-#{ctx.claude.id} [data-runtime-status="online"]))
      assert has_element?(view, "#runtime-#{ctx.claude.id} [data-models]", "2")

      assert has_element?(
               view,
               ~s(#runtime-#{ctx.codex.id} [data-runtime-status="unavailable"]),
               "不可用"
             )

      assert has_element?(view, "#runtime-#{ctx.codex.id} [data-unavailable-reason]", "too old")
      refute has_element?(view, "#runtime-#{ctx.bob_rt.id}")
    end

    test "bound agents link to their page", ctx do
      managed_agent_fixture(scope(ctx, :alice), %{name: "keel/dev", runtime_id: ctx.claude.id})
      {:ok, view, _html} = open(ctx, :alice)

      assert has_element?(
               view,
               ~s(#runtime-#{ctx.claude.id} a[data-agent="keel/dev"][href="/w/#{ctx.ws.slug}/agents/keel/dev"])
             )
    end

    test "an admin switches to all runtimes", ctx do
      {:ok, view, _html} = open(ctx, :adam)
      # No machine of their own: the empty state, and still the switch.
      assert has_element?(view, "#runtimes-empty")
      assert has_element?(view, "#runtimes-none")

      view |> element("#runtimes-all") |> render_click()
      assert_patch(view, ctx.path <> "?all=1")

      assert has_element?(view, "#runtime-#{ctx.bob_rt.id} [data-owner]", "bob")
      assert has_element?(view, "#runtime-#{ctx.claude.id} [data-owner]", "alice")
      # An admin may disable other members' runtimes.
      assert has_element?(view, "#runtime-#{ctx.bob_rt.id}-disable")
    end

    test "a member sees only their runtimes, even with ?all=1", ctx do
      {:ok, view, _html} = open(ctx, :bob, ctx.path <> "?all=1")

      assert has_element?(view, "#runtime-#{ctx.bob_rt.id}")
      refute has_element?(view, "#runtime-#{ctx.claude.id}")
      refute has_element?(view, "#runtimes-scope")
      refute has_element?(view, "[data-owner]")
      assert has_element?(view, "#runtime-#{ctx.bob_rt.id}-disable")
    end

    test "without any machine there is the empty state with the login command", ctx do
      carol = user_fixture()
      member_fixture(ctx.ws, carol, :member)
      {:ok, view, _html} = live(log_in_user(ctx.conn, carol), ctx.path)

      assert has_element?(view, "#runtimes-empty")
      command = "helmsman login --server #{HelmsmanWeb.Endpoint.url()}"
      assert has_element?(view, "#login-command-text", command)
      assert has_element?(view, "#login-command")
      assert has_element?(view, "#start-command-text", "helmsman daemon start")
      refute has_element?(view, "#daemons-section")
    end

    test "a viewer goes back to the settings", ctx do
      assert {:ok, _view, html} =
               ctx
               |> open(:vic)
               |> follow_redirect(
                 log_in_user(ctx.conn, ctx.users.vic),
                 "/w/#{ctx.ws.slug}/settings"
               )

      assert html =~ "没有权限访问运行时"
    end
  end

  describe "actions" do
    test "disable after confirming, then enable", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      view |> element("#runtime-#{ctx.claude.id}-disable") |> render_click()
      assert in_portal?(view, "runtimes-confirm", "#runtimes-confirm-description", "排队中的运行会被取消")

      render_click(view, "disable", %{"id" => ctx.claude.id})

      assert has_element?(
               view,
               ~s(#runtime-#{ctx.claude.id} [data-runtime-status="disabled"]),
               "已禁用"
             )

      view |> element("#runtime-#{ctx.claude.id}-enable") |> render_click()
      assert has_element?(view, ~s(#runtime-#{ctx.claude.id} [data-runtime-status="online"]))
      assert has_element?(view, "#runtime-#{ctx.claude.id}-disable")
    end

    test "revoking a machine", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      render_click(view, "ask_revoke", %{"id" => ctx.mbp.id})

      assert in_portal?(
               view,
               "runtimes-confirm",
               "#runtimes-confirm-description",
               "需要重新 helmsman login"
             )

      render_click(view, "revoke", %{"id" => ctx.mbp.id})
      assert has_element?(view, "#daemon-#{ctx.mbp.id} [data-revoked-badge]", "已吊销")
      refute has_element?(view, "#daemon-#{ctx.mbp.id}-actions-trigger")
      assert has_element?(view, ~s(#runtime-#{ctx.claude.id} [data-runtime-status="offline"]))
    end

    test "renaming", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=rename:#{ctx.mbp.id}")
      assert open?(view, "daemon-panel")

      render_submit(view, "rename", %{"rename" => %{"name" => "  "}})
      assert in_portal?(view, "daemon-panel", "#rename-form", "请填写名字")
      assert open?(view, "daemon-panel")

      render_submit(view, "rename", %{"rename" => %{"name" => String.duplicate("x", 65)}})
      assert in_portal?(view, "daemon-panel", "#rename-form", "64")

      render_submit(view, "rename", %{"rename" => %{"name" => "studio"}})
      assert_patch(view, ctx.path)
      assert has_element?(view, "#daemon-#{ctx.mbp.id} [data-daemon-name]", "studio")
    end

    test "the workspaces a machine serves", ctx do
      beta = workspace_fixture(ctx.users.alice, %{name: "Beta"})

      Daemons.set_workspaces(Scope.for_user(ctx.users.alice), ctx.mbp.id, [
        ctx.ws.id,
        beta.id
      ])

      gamma = workspace_fixture(ctx.users.bob, %{name: "Gamma"})
      member_fixture(gamma, ctx.users.alice, :member)

      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=workspaces:#{ctx.mbp.id}")
      assert has_element?(view, "#daemon-#{ctx.mbp.id} [data-daemon-workspaces]", "Beta")
      assert in_portal?(view, "daemon-panel", "#daemon-workspace-#{beta.id} input[checked]")

      render_submit(view, "save_workspaces", %{"workspace_ids" => ["", to_string(ctx.ws.id)]})
      refute has_element?(view, "#daemon-#{ctx.mbp.id} [data-daemon-workspaces]", "Beta")

      render_patch(view, ctx.path <> "?panel=workspaces:#{ctx.mbp.id}")
      assert in_portal?(view, "daemon-panel", "#daemon-workspace-#{gamma.id}")

      # Alice becomes a viewer of Gamma while the panel is open.
      Repo.update_all(
        from(m in Helmsman.Workspaces.Membership,
          where: m.workspace_id == ^gamma.id and m.user_id == ^ctx.users.alice.id
        ),
        set: [role: :viewer]
      )

      render_submit(view, "save_workspaces", %{"workspace_ids" => ["", to_string(gamma.id)]})
      assert in_portal?(view, "daemon-panel", ~s(#daemon-workspace-#{gamma.id}[data-invalid]))
    end

    test "a member cannot change another member's runtime", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      refute has_element?(view, "#runtime-#{ctx.claude.id}-disable")

      render_click(view, "disable", %{"id" => ctx.claude.id})
      assert Runtimes.list(scope(ctx, :alice)) |> elem(1) |> Enum.all?(&(not &1.disabled))
    end

    test "an admin disables another member's runtime", ctx do
      {:ok, view, _html} = open(ctx, :adam, ctx.path <> "?all=1")
      render_click(view, "disable", %{"id" => ctx.bob_rt.id})
      assert has_element?(view, ~s(#runtime-#{ctx.bob_rt.id} [data-runtime-status="disabled"]))
    end
  end

  describe "live updates" do
    test "a machine coming online appears without a reload", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      pid = view.pid
      {studio, _} = daemon_fixture(ctx.users.alice, %{name: "studio", workspace_ids: [ctx.ws.id]})

      {:ok, machine} =
        Machine.new(%{
          machine_id: studio.machine_id,
          name: "studio",
          os: "linux",
          arch: "x86_64",
          daemon_version: "1.0.0"
        })

      report = %Report.Join{
        protocol: HelmsmanProtocol.version(),
        machine: machine,
        clis: [
          %CLI{provider: :copilot, version: "1.0.0", models: [], efforts: [], available: true}
        ],
        max_concurrency: 2,
        active_runs: []
      }

      assert {:ok, [_]} = Daemons.register(studio.id, studio.auth_epoch, report)

      eventually(fn -> has_element?(view, ~s([data-provider="copilot"])) end)
      assert has_element?(view, "#daemon-#{studio.id}")
      assert view.pid == pid
    end

    test "a machine revoked in another window", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      {:ok, _} = Daemons.revoke(Scope.for_user(ctx.users.alice), ctx.mbp.id)
      eventually(fn -> has_element?(view, "#daemon-#{ctx.mbp.id} [data-revoked-badge]") end)
    end

    test "an open rename panel keeps its input across a reload", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.path <> "?panel=rename:#{ctx.mbp.id}")
      render_change(view, "validate_rename", %{"rename" => %{"name" => "half-typed"}})

      send(view.pid, {:runtimes_changed})
      send(view.pid, :reload)
      render(view)

      assert open?(view, "daemon-panel")
      assert portal_attr(view, "daemon-panel", "#rename-name", "value") == "half-typed"
    end

    test "the tick re-reads the online state", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, ~s(#daemon-#{ctx.mbp.id} [data-presence="online"]))

      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.mbp.id),
        set: [last_seen_at: DateTime.add(DateTime.utc_now(:second), -600)]
      )

      send(view.pid, :tick)
      assert has_element?(view, ~s(#daemon-#{ctx.mbp.id} [data-presence="offline"]))
    end
  end
end

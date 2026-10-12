defmodule HelmsmanWeb.AgentLive.IndexTest do
  @moduledoc "Spec web-agents Agent 列表页、Agent 入口、Agent 页实时刷新 (design D3, D4)."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures, only: [agent_actor: 2, run_fixture: 2]
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Daemons, Presence, Repo}
  alias Helmsman.Daemons.Runtime
  alias HelmsmanWeb.AgentLive.Index

  setup %{conn: conn} do
    _admin = user_fixture()
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    bob = user_fixture(%{display_name: "bob"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, bob, :member)
    member_fixture(ws, vic, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)

    managed_agent_fixture(alice_scope, %{name: "keel/dev"})
    dev = agent_actor(ws, "keel/dev")

    Repo.insert!(%Actor{
      workspace_id: ws.id,
      kind: :agent,
      name: "bob/session-a1b2c3",
      owner_id: bob.id
    })

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, bob: bob, vic: vic},
      alice_scope: alice_scope,
      dev: dev,
      path: "/w/#{ws.slug}/agents"
    }
  end

  defp open(ctx, who, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path || ctx.path)

  defp row(name), do: "#agent-#{Index.dom_key(name)}"

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "list content: status, owner, kind, CLI and machine, queue", ctx do
    run_fixture(ctx.dev, %{status: :running})
    run_fixture(ctx.dev, %{status: :queued})
    run_fixture(ctx.dev, %{status: :queued})

    {:ok, view, _html} = open(ctx, :alice)

    assert page_title(view) == "Agents · Acme"
    assert has_element?(view, ~s(#{row("keel/dev")} [data-agent-status="busy"]), "忙碌（1）")
    assert has_element?(view, "#{row("keel/dev")} [data-owner]", "alice")
    assert has_element?(view, "#{row("keel/dev")} [data-kind]", "托管")
    assert has_element?(view, "#{row("keel/dev")} [data-cli]", "Claude Code")
    assert has_element?(view, "#{row("keel/dev")} [data-cli]", "test-machine")
    assert has_element?(view, "#{row("keel/dev")} [data-queued]", "2")

    ext = row("bob/session-a1b2c3")
    assert has_element?(view, "#{ext} [data-kind]", "外接")
    refute has_element?(view, "#{ext} [data-agent-status]")
    refute has_element?(view, "#{ext} [data-cli]")
  end

  test "an idle agent and one without a runtime", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/qa", runtime_id: nil})
    {:ok, view, _html} = open(ctx, :alice)

    assert has_element?(view, ~s(#{row("keel/dev")} [data-agent-status="idle"]), "空闲")
    assert has_element?(view, ~s(#{row("keel/qa")} [data-agent-status="offline"]), "离线")
    assert has_element?(view, "#{row("keel/qa")} [data-cli]", "未绑定运行时")
  end

  test "archived agents are hidden until 显示已归档", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/old"})
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/old")
    {:ok, view, _html} = open(ctx, :alice)

    refute has_element?(view, row("keel/old"))
    view |> element("#agents-archived") |> render_click()
    assert_patch(view, ctx.path <> "?archived=1")
    assert has_element?(view, ~s(#{row("keel/old")} [data-agent-status="archived"]), "已归档")
  end

  test "owner=me lists only the user's agents", ctx do
    {:ok, view, _html} = open(ctx, :bob)
    view |> element("#agents-mine") |> render_click()
    assert_patch(view, ctx.path <> "?owner=me")

    assert has_element?(view, row("bob/session-a1b2c3"))
    refute has_element?(view, row("keel/dev"))
  end

  test "a viewer sees every agent and cannot create one", ctx do
    {:ok, view, _html} = open(ctx, :vic)
    assert has_element?(view, row("keel/dev"))
    assert has_element?(view, row("bob/session-a1b2c3"))
    refute has_element?(view, "#agents-new")
  end

  test "an external agent with a session online", ctx do
    {:ok, _} =
      Presence.track(self(), Presence.agents_topic(ctx.ws.id), "s-1", %{
        actor_name: "bob/session-a1b2c3"
      })

    {:ok, view, _html} = open(ctx, :alice)
    assert has_element?(view, ~s(#{row("bob/session-a1b2c3")} [data-agent-status="online"]), "在线")
  end

  test "the empty state", ctx do
    owner = user_fixture()
    empty = workspace_fixture(owner)
    {:ok, view, _html} = live(log_in_user(ctx.conn, owner), "/w/#{empty.slug}/agents")

    assert has_element?(view, "#agents-empty", "外接 Agent")
    assert has_element?(view, "#agents-empty a", "新建 Agent")
  end

  test "rows link to the detail page", ctx do
    {:ok, view, _html} = open(ctx, :alice)

    assert has_element?(
             view,
             ~s(#{row("keel/dev")} a[data-agent-link][href="/w/#{ctx.ws.slug}/agents/keel/dev"])
           )

    assert has_element?(view, ~s(#{row("keel/dev")}[phx-click*="/agents/keel/dev"]))
  end

  test "the sidebar marks Agents on a detail page", ctx do
    {:ok, view, _html} = open(ctx, :vic, ctx.path <> "/keel/dev")
    assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "Agents")
  end

  describe "live updates" do
    test "a disable in another window", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      pid = view.pid
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")

      eventually(fn ->
        has_element?(view, ~s(#{row("keel/dev")} [data-agent-status="disabled"]), "已停用")
      end)

      assert view.pid == pid
    end

    test "the runtime going offline", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      {:ok, agent} = Agents.get(ctx.alice_scope, "keel/dev")
      daemon_id = Repo.get!(Runtime, agent.runtime.id).daemon_id
      {:ok, _} = Helmsman.Tx.run(fn -> {:ok, Daemons.offline(daemon_id, [ctx.ws.id])} end)

      eventually(fn ->
        has_element?(view, ~s(#{row("keel/dev")} [data-agent-status="offline"]))
      end)
    end

    test "several notifications within 500ms reload once", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      test = self()
      handler = "agents-reload-#{inspect(test)}"

      :telemetry.attach(
        handler,
        [:helmsman_web, :run_data, :agents],
        fn _event, _measurements, %{workspace_id: id}, _ ->
          if id == ctx.ws.id, do: send(test, :agents_listed)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for _ <- 1..5, do: send(view.pid, {:agents_changed})
      send(view.pid, {:runtimes_changed})

      assert_receive :agents_listed, 1_000
      refute_receive :agents_listed, 700
    end
  end
end

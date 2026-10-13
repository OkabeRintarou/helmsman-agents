defmodule HelmsmanWeb.Components.ActorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Actor

  @agent %{name: "keel/dev", kind: :agent, owner_name: "alice", managed?: true}

  test "four kinds of actors" do
    assert render_component(&actor_chip/1, actor: %{name: "alice", kind: :human}) =~ ">A</span>"
    assert render_component(&actor_chip/1, actor: @agent) =~ "lucide-bot"
    assert render_component(&actor_chip/1, actor: %{name: "core", kind: :squad}) =~ "lucide-users"

    system = render_component(&actor_chip/1, actor: %{name: "system", kind: "system"})
    assert system =~ "lucide-settings"
    assert system =~ "text-fg-muted"
  end

  test "agent tooltip shows the owner and managed / external" do
    html = render_component(&actor_chip/1, actor: @agent)
    assert html =~ "所属：alice · 托管"
    assert html =~ "hm-tooltip"

    external = render_component(&actor_chip/1, actor: %{@agent | managed?: false})
    assert external =~ "所属：alice · 外接"
  end

  test "an agent reference without `managed?` claims neither 托管 nor 外接" do
    bare = render_component(&actor_chip/1, actor: %{name: "keel/dev", kind: "agent"})
    refute bare =~ ~r/托管|外接/

    owned = render_component(&actor_chip/1, actor: Map.delete(@agent, :managed?))
    assert owned =~ "所属：alice"
    refute owned =~ ~r/托管|外接/
  end

  test "compact mode keeps the name for the tooltip and assistive technology" do
    html = render_component(&actor_chip/1, actor: @agent, compact: true)
    assert html =~ ~r/<span class="truncate sr-only">\s*keel\/dev\s*<\/span>/
    assert html =~ "keel/dev · 所属：alice · 托管"
  end

  test "unavailable actors are dimmed and expose the reason" do
    html = render_component(&actor_chip/1, actor: @agent, disabled_reason: "你无权触发 keel/dev")
    assert html =~ "opacity-60"
    assert html =~ ~r/<span class="sr-only">\s*你无权触发 keel\/dev\s*<\/span>/
    assert html =~ ~s(tabindex="0")
  end

  test "disabled and archived suffixes" do
    assert render_component(&actor_chip/1,
             actor: %{@agent | name: "a"} |> Map.put(:state, :disabled)
           ) =~
             "a（已停用）"

    assert render_component(&actor_chip/1, actor: Map.put(@agent, :state, "archived")) =~
             "keel/dev（已归档）"
  end

  test "presence dot" do
    assert render_component(&presence_dot/1, status: :online) =~ "bg-success"
    assert render_component(&presence_dot/1, status: :busy) =~ "bg-brand"
    assert render_component(&presence_dot/1, status: :offline) =~ "border-fg-subtle"
    assert render_component(&presence_dot/1, status: nil) == ""

    assert render_component(&actor_chip/1, actor: @agent, presence: :online) =~
             ~s(aria-label="在线")
  end

  test "working chip names the first agent and counts the rest" do
    one = render_component(&working_chip/1, id: "w", agents: ["keel/dev"])
    assert one =~ "keel/dev 正在处理"

    two =
      render_component(&working_chip/1,
        id: "w",
        agents: ["keel/dev", "keel/reviewer"],
        on_click: "open_run"
      )

    assert two =~ "keel/dev 等 2 个正在处理"
    assert two =~ "keel/dev、keel/reviewer"
    assert two =~ ~s(phx-click="open_run")
    assert two =~ ~s(aria-describedby="w-tip")

    assert render_component(&working_chip/1, id: "w", agents: []) == ""
  end
end

defmodule HelmsmanWeb.Components.ActorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Actor

  @agent %{name: "keel/dev", kind: :agent, owner_name: "alice", managed?: true}

  test "four kinds of actors" do
    assert render_component(&actor_chip/1, actor: %{name: "alice", kind: :human}) =~ ">A</text>"
    assert render_component(&actor_chip/1, actor: @agent) =~ "lucide-bot"
    assert render_component(&actor_chip/1, actor: %{name: "core", kind: :squad}) =~ "lucide-users"

    system = render_component(&actor_chip/1, actor: %{name: "system", kind: "system"})
    assert system =~ "lucide-settings"
    assert system =~ "text-fg-muted"
  end

  describe "actor_mark/1 (add-actor-avatars D2, web-components 身份标记)" do
    defp mark(actor, opts \\ []),
      do: render_component(&actor_mark/1, Keyword.merge([actor: actor], opts))

    test "default marks: human circle, CLI plate, neutral bot, squad, system" do
      human = mark(%{name: "alice", kind: :human})
      assert human =~ "rounded-full"
      assert human =~ ">A</text>"
      assert human =~ ~r/bg-id-tint-[1-8] text-id-tint-[1-8]-ink/

      codex = mark(%{name: "keel/review", kind: :agent, provider: "codex", managed?: true})
      assert codex =~ "rounded-[25%]"
      assert codex =~ ~s(data-brand="codex")
      assert codex =~ "/images/brand/codex-color.svg"

      external = mark(%{name: "x/dev", kind: :agent, managed?: false, provider: "codex"})
      assert external =~ "lucide-bot"
      assert external =~ "bg-id-neutral"

      squad = mark(%{name: "backend-team", kind: :squad})
      assert squad =~ "lucide-users"
      assert squad =~ "bg-id-squad text-id-squad-ink"

      system = mark(%{name: "helmsman", kind: :system, avatar_url: "/x.png"})
      assert system =~ "lucide-settings"
      assert system =~ "border-border-strong"
      refute system =~ "<img"
    end

    test "an Agent with an unknown CLI shows the neutral bot (spec 未知键)" do
      html = mark(%{name: "a", kind: :agent, provider: "bar", managed?: true})
      assert html =~ "lucide-bot"
      assert html =~ ~s(data-brand="none")
    end

    test "monochrome CLI icons are inlined on the plate (copilot)" do
      html = mark(%{name: "a", kind: :agent, provider: "copilot", managed?: true})
      assert html =~ ~s(data-brand="githubcopilot")
      assert html =~ "<svg class="
      refute html =~ ~s(width="1em")
    end

    test "custom avatars cover the default mark, cut to the identity's shape" do
      agent = mark(%{name: "keel/dev", kind: :agent, provider: "claude", avatar_url: "/a.webp"})
      assert agent =~ ~r/<img data-avatar[^>]*src="\/a.webp"/
      assert agent =~ "rounded-[25%]"
      assert agent =~ ~s(data-brand="claude")

      human = mark(%{name: "alice", kind: :human, avatar_url: "/b.webp"})
      assert human =~ "rounded-full"
      assert human =~ ~s(src="/b.webp")
    end

    test "disabled and archived identities are desaturated" do
      assert mark(%{name: "keel/old", kind: :agent, state: :disabled}) =~ "opacity-70 grayscale"
      assert mark(%{name: "s", kind: :squad, state: "archived"}) =~ "grayscale"
      refute mark(%{name: "s", kind: :squad}) =~ "grayscale"
    end

    test "the initial's tint is stable per name" do
      assert tint_index("alice") == tint_index("alice")
      assert tint_index("alice") in 1..8
      a = mark(%{name: "alice", kind: :human})
      b = mark(%{name: "alice", kind: "human"}, size: :lg)
      [tint] = Regex.run(~r/data-tint="(\d)"/, a, capture: :all_but_first)
      assert b =~ ~s(data-tint="#{tint}")
      assert tint == to_string(tint_index("alice"))
    end

    test "sizes and accessible name" do
      assert mark(%{name: "a", kind: :human}) =~ "size-5"
      assert mark(%{name: "a", kind: :human}, size: :xs) =~ "size-4"
      assert mark(%{name: "a", kind: :human}, size: :md) =~ "size-7"
      assert mark(%{name: "a", kind: :human}, size: :lg) =~ "size-10"
      assert mark(%{name: "a", kind: :human}, size: :xl) =~ "size-16"

      assert mark(%{name: "a", kind: :human}) =~ ~r/data-actor-mark="human" aria-hidden="true"/
      labelled = mark(%{name: "a", kind: :human}, label: "alice 的头像")
      assert labelled =~ ~s(role="img")
      assert labelled =~ ~s(aria-label="alice 的头像")
    end
  end

  test "managed Agents' tooltip names the CLI (D8)" do
    html = render_component(&actor_chip/1, actor: Map.put(@agent, :provider, "claude"))
    assert html =~ "所属：alice · 托管 · Claude Code"
    assert html =~ ~s(data-brand="claude")

    external =
      render_component(&actor_chip/1,
        actor: %{@agent | managed?: false} |> Map.put(:provider, "claude")
      )

    assert external =~ "所属：alice · 外接"
    refute external =~ "Claude Code"
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

  test "unclaimed humans are marked (add-data-settings-ui D11)" do
    html =
      render_component(&actor_chip/1, actor: %{name: "robert", kind: :human, unclaimed: true})

    assert html =~ "robert（未认领）"
    assert html =~ "导入的身份，尚未被成员认领"
    assert html =~ ~r/<span class="sr-only">\s*导入的身份，尚未被成员认领\s*<\/span>/
    assert html =~ ~s(tabindex="0")

    by_state =
      render_component(&actor_chip/1, actor: %{name: "robert", kind: "human", state: "unclaimed"})

    assert by_state =~ "robert（未认领）"

    refute render_component(&actor_chip/1,
             actor: %{name: "alice", kind: :human, unclaimed: false}
           ) =~
             "未认领"

    refute render_component(&actor_chip/1, actor: %{name: "x/dev", kind: :agent, unclaimed: true}) =~
             "未认领"
  end

  test "task summaries keep the unclaimed flag (TaskComponents.actor_ref)" do
    html =
      render_component(&HelmsmanWeb.TaskComponents.actor_ref/1,
        actor: %{name: "robert", kind: "human", unclaimed: true}
      )

    assert html =~ "robert（未认领）"

    refute render_component(&HelmsmanWeb.TaskComponents.actor_ref/1,
             actor: %{name: "alice", kind: "human"}
           ) =~ "未认领"
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

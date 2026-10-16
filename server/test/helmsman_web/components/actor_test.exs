defmodule HelmsmanWeb.Components.ActorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Actor

  alias Helmsman.Avatars.Icons

  @agent %{name: "keel/dev", kind: :agent, owner_name: "alice", managed?: true}

  test "four kinds of actors" do
    assert render_component(&actor_chip/1, actor: %{name: "alice", kind: :human}) =~ ">A</text>"
    assert render_component(&actor_chip/1, actor: @agent) =~ "lucide-bot"
    assert render_component(&actor_chip/1, actor: %{name: "core", kind: :squad}) =~ "lucide-users"

    system = render_component(&actor_chip/1, actor: %{name: "system", kind: "system"})
    assert system =~ "lucide-settings"
    assert system =~ "text-fg-muted"
  end

  # A chip in a `truncate` cell inherits `white-space: nowrap`; an unwrapped tooltip
  # overflows the cell even while hidden, and Firefox then replaces the whole chip
  # with the ellipsis.
  test "the chip's tooltip wraps even inside a nowrap cell" do
    html = render_component(&actor_chip/1, actor: @agent)
    assert [tooltip] = Regex.run(~r/<span aria-hidden="true" class="hm-tooltip[^"]*"/, html)
    assert tooltip =~ "whitespace-normal"
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

      assert mark(%{name: "a", kind: :human}) =~
               ~r/data-actor-mark="human"[^>]*aria-hidden="true"/

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

  describe "update-actor-icons D4, D11 (web-components 身份标记 / Actor 标识)" do
    @claude %{
      name: "keel/dev",
      kind: :agent,
      owner_name: "alice",
      managed?: true,
      provider: "claude"
    }

    defp source(html), do: Regex.run(~r/data-mark="(\w+)"/, html, capture: :all_but_first)
    defp brand(html), do: Regex.run(~r/data-brand="([\w-]+)"/, html, capture: :all_but_first)
    defp chip(actor), do: render_component(&actor_chip/1, actor: actor)

    test "各类缺省标记: initial circle, Codex plate, neutral bot, squad, system" do
      marks = [
        mark(%{name: "alice", kind: :human}),
        mark(%{name: "keel/review", kind: :agent, managed?: true, provider: "codex"}),
        mark(%{name: "x/dev", kind: :agent, managed?: false, provider: "codex", vendor: "zai"}),
        mark(%{name: "backend-team", kind: :squad}),
        mark(%{name: "helmsman", kind: :system, avatar_icon: "openai"})
      ]

      assert Enum.map(marks, &source/1) ==
               [["default"], ["cli"], ["default"], ["default"], ["default"]]

      [alice, codex, external, squad, system] = marks
      assert alice =~ ">A</text>"
      assert brand(codex) == ["codex"]
      assert external =~ "lucide-bot"
      assert squad =~ "lucide-users"
      assert system =~ "lucide-settings"
      refute system =~ "data-brand"
    end

    test "账号厂商优先 / 运行时厂商: the vendor replaces the CLI icon" do
      account = Map.merge(@claude, %{vendor: "zai", vendor_source: :account})
      assert source(mark(account)) == ["vendor"]
      assert brand(mark(account)) == ["zai"]

      runtime = Map.merge(@claude, %{vendor: "zai", vendor_source: :runtime})
      assert brand(mark(runtime)) == ["zai"]

      # Old daemon: no vendor; an account that is not recognised: nil vendor (D4 领域 1).
      assert brand(mark(@claude)) == ["claude"]

      assert brand(mark(Map.merge(@claude, %{vendor: nil, vendor_source: :account}))) == [
               "claude"
             ]
    end

    test "unknown vendors and icons count as absent" do
      assert brand(mark(Map.put(@claude, :vendor, "newco"))) == ["claude"]
      assert brand(mark(Map.put(@claude, :avatar_icon, "nope"))) == ["claude"]
      assert source(mark(%{name: "alice", kind: :human, avatar_icon: "nope"})) == ["default"]
      # A CLI icon is not a vendor: the vendor must be in the vendor or platform table.
      assert brand(mark(Map.put(@claude, :vendor, "codex"))) == ["claude"]
      # Platforms count as vendors.
      assert brand(mark(Map.put(@claude, :vendor, "bedrock"))) == ["bedrock"]
    end

    test "external Agents never show a vendor or CLI, only their built-in icon" do
      external = %{@claude | managed?: false} |> Map.put(:vendor, "zai")
      assert external |> mark() |> source() == ["default"]
      assert external |> Map.put(:avatar_icon, "kimi") |> mark() |> brand() == ["kimi"]
    end

    test "内置图标: a circle for people, a rounded square for Agents and squads" do
      alice = mark(%{name: "alice", kind: :human, avatar_icon: "openai"})
      assert source(alice) == ["icon"]
      assert brand(alice) == ["openai"]

      refute alice =~ ">A</text>"

      [plate] =
        Regex.run(~r/class="([^"]*)"\s+data-brand="openai"/, alice, capture: :all_but_first)

      assert plate =~ "rounded-full"
      assert plate =~ "bg-id-plate"
      assert plate =~ "border-id-plate-border"

      squad = mark(%{name: "backend-team", kind: :squad, avatar_icon: "claude"})
      assert brand(squad) == ["claude"]
      refute squad =~ "lucide-users"

      [plate] =
        Regex.run(~r/class="([^"]*)"\s+data-brand="claude"/, squad, capture: :all_but_first)

      assert plate =~ "rounded-[25%]"

      # The icon is 70% of the edge (inside the circle's inscribed square, ~70.7%).
      assert alice =~ ~r/(size-\[70%\])/
    end

    test "the built-in icon wins over the vendor and the CLI; the image over all" do
      agent = Map.merge(@claude, %{vendor: "zai", avatar_icon: "deepseek"})
      assert brand(mark(agent)) == ["deepseek"]

      image = mark(Map.put(agent, :avatar_url, "/a.webp"))
      assert image =~ ~s(src="/a.webp")
      # Under the image, the mark the identity falls back to from level 2 on.
      assert brand(image) == ["deepseek"]
    end

    test "disabled identities with a built-in icon are desaturated too" do
      html = mark(%{name: "s", kind: :squad, avatar_icon: "qwen", state: :disabled})
      assert html =~ "opacity-70 grayscale"
    end

    test "带厂商的提示: the vendor's name follows the CLI" do
      html = chip(Map.merge(@claude, %{vendor: "zai", vendor_source: :account}))
      assert html =~ "所属：alice · 托管 · Claude Code · Z.ai"

      plain = chip(@claude)
      assert plain =~ "所属：alice · 托管 · Claude Code"
      refute plain =~ "Z.ai"
    end

    test "内置图标的提示, for every kind, readable by assistive technology" do
      dave = chip(%{name: "dave", kind: :human, avatar_icon: "deepseek"})
      assert dave =~ "图标：DeepSeek"
      assert dave =~ ~r/<span class="sr-only">\s*图标：DeepSeek\s*<\/span>/
      assert dave =~ ~s(tabindex="0")

      squad = chip(%{name: "backend-team", kind: :squad, avatar_icon: "githubcopilot"})
      assert squad =~ "图标：GitHub Copilot"

      agent = chip(Map.merge(@claude, %{avatar_icon: "zai", vendor: "openai"}))
      assert agent =~ "所属：alice · 托管 · Claude Code · 图标：Z.ai"
      refute agent =~ "OpenAI"

      compact =
        render_component(&actor_chip/1,
          actor: Map.put(@claude, :avatar_icon, "zai"),
          compact: true
        )

      assert compact =~ "keel/dev · 所属：alice · 托管 · Claude Code · 图标：Z.ai"
    end

    test "an image avatar names neither the icon nor the vendor" do
      html = chip(Map.merge(@claude, %{vendor: "zai", avatar_url: "/a.webp"}))
      assert html =~ ~r/<span class="sr-only">\s*所属：alice · 托管 · Claude Code\s*<\/span>/
      refute chip(%{name: "dave", kind: :human, avatar_url: "/a", avatar_icon: "openai"}) =~ "图标："
    end

    test "Brands.icon_names/0 equals the domain's icon keys (D2)" do
      assert Enum.sort(HelmsmanWeb.Brands.icon_names()) ==
               Enum.sort(Icons.keys())
    end
  end
end

defmodule HelmsmanWeb.IdentityRenderTest do
  @moduledoc """
  web-components「Actor 标识」: identities are drawn only by `actor_chip` /
  `actor_mark` (add-actor-avatars D7). Scans `lib/helmsman_web/` for the old ways of
  drawing one; the allow-list holds the uses that are not identities (navigation,
  empty states, the icon showcase, a dispatch result) and the components themselves.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @allowed %{
    ~r/kind_icon/ => [],
    ~r/<\.avatar[\s>]/ => [],
    ~r/lucide-bot/ => [
      # the neutral mark / CLI fallback
      "lib/helmsman_web/components/brand.ex",
      # the icon/1 doc example
      "lib/helmsman_web/components/core_components.ex",
      # the Agents navigation item
      "lib/helmsman_web/nav.ex",
      # the icon showcase
      "lib/helmsman_web/live/dev/ui_live.ex",
      # empty states (no identity)
      "lib/helmsman_web/live/agent_live/index.ex",
      "lib/helmsman_web/live/agent_design_live.ex",
      # the result icon of a dispatch history entry (started / skipped)
      "lib/helmsman_web/collab_components.ex"
    ],
    ~r/lucide-users["\s]/ => [
      "lib/helmsman_web/components/actor.ex",
      "lib/helmsman_web/nav.ex",
      "lib/helmsman_web/live/dev/ui_live.ex",
      "lib/helmsman_web/live/squad_live/index.ex"
    ],
    ~r/lucide-user["\s]/ => []
  }

  test "identities are only drawn by actor_chip / actor_mark" do
    files =
      @root
      |> Path.join("lib/helmsman_web/**/*.{ex,heex}")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, @root), File.read!(&1)})

    offenders =
      for {pattern, allowed} <- @allowed,
          {path, source} <- files,
          path not in allowed,
          Regex.match?(pattern, source),
          do: {inspect(pattern), path}

    assert offenders == []
  end

  test "the avatar/1 component is gone (actor_mark/1 replaces it)" do
    Code.ensure_loaded!(HelmsmanWeb.Components.Actor)
    refute function_exported?(HelmsmanWeb.Components.Actor, :avatar, 1)
    assert function_exported?(HelmsmanWeb.Components.Actor, :actor_mark, 1)
  end
end

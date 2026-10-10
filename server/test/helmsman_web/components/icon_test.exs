defmodule HelmsmanWeb.Components.IconTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.CoreComponents, only: [icon: 1]

  test "decorative icons are hidden from assistive technology" do
    html = render_component(&icon/1, name: "lucide-bot")
    assert html =~ ~s(class="lucide-bot size-4")
    assert html =~ ~s(aria-hidden="true")
    refute html =~ "role="
  end

  test "labelled icons are exposed as images" do
    html = render_component(&icon/1, name: "lucide-bot", label: "Agent", class: "size-3.5")
    assert html =~ ~s(role="img")
    assert html =~ ~s(aria-label="Agent")
    assert html =~ "size-3.5"
    refute html =~ "aria-hidden"
  end

  test "every Lucide icon referenced in lib/ exists in the icon set" do
    icons_dir = Path.expand("../../../deps/lucide/icons", __DIR__)

    used =
      Path.wildcard(Path.expand("../../../lib/**/*.{ex,heex}", __DIR__))
      |> Enum.flat_map(
        &Regex.scan(~r/lucide-([a-z0-9-]+)/, File.read!(&1), capture: :all_but_first)
      )
      |> List.flatten()
      |> Enum.uniq()

    assert used != []
    assert Enum.reject(used, &File.exists?(Path.join(icons_dir, "#{&1}.svg"))) == []
  end
end

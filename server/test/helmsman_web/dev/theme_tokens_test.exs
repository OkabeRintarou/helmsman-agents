defmodule HelmsmanWeb.Dev.ThemeTokensTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.Dev.ThemeTokens

  @tolerance 0.05

  # Worst-case ratios from design D3: {graphic over BG4, text over BG4 + own badge background}.
  @semantic %{
    "helmsman-light" => %{
      "brand" => {4.19, 4.72},
      "success" => {3.24, 4.74},
      "warning" => {3.03, 4.80},
      "danger" => {4.15, 4.71},
      "info" => {3.46, 4.86},
      "review" => {4.16, 4.74}
    },
    "helmsman-dark" => %{
      "brand" => {5.66, 5.78},
      "success" => {5.76, 5.83},
      "warning" => {7.14, 6.97},
      "danger" => {4.68, 5.49},
      "info" => {5.45, 5.61},
      "review" => {5.21, 5.46}
    }
  }

  # {fg-muted, fg-subtle, fg at 60% opacity}
  @neutral %{
    "helmsman-light" => {5.25, 3.17, 4.22},
    "helmsman-dark" => {5.45, 3.72, 5.24}
  }

  @buttons %{
    "helmsman-light" => %{"on-brand" => 5.21, "on-danger" => 5.15, "on-warning" => 4.58},
    "helmsman-dark" => %{"on-brand" => 8.07, "on-danger" => 6.67}
  }

  defp worst(theme, filter) do
    theme
    |> ThemeTokens.checks()
    |> Enum.filter(filter)
    |> tap(&assert &1 != [])
    |> Enum.min_by(& &1.ratio)
  end

  defp assert_worst(theme, filter, expected, threshold) do
    check = worst(theme, filter)
    assert check.threshold == threshold
    assert check.ratio >= threshold
    assert_in_delta check.ratio, expected, @tolerance
  end

  test "parses both themes from app.css" do
    assert ThemeTokens.themes() == ["helmsman-light", "helmsman-dark"]
    assert ThemeTokens.badge_mix("helmsman-light") == 0.12
    assert ThemeTokens.badge_mix("helmsman-dark") == 0.16
    assert ThemeTokens.tokens("helmsman-light")["surface"] == {1.0, 0.0, 0.0, 1.0}
    assert ThemeTokens.tokens("helmsman-dark")["border"] == {1.0, 0.0, 0.0, 0.08}
  end

  test "contrast follows WCAG 2.x" do
    assert_in_delta ThemeTokens.contrast({0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}), 21.0, 0.001
    assert ThemeTokens.oklch_to_srgb(1, 0, 0) |> Tuple.to_list() |> Enum.all?(&(&1 > 0.999))
  end

  for theme <- ["helmsman-light", "helmsman-dark"] do
    describe theme do
      @theme theme

      test "every check passes its threshold" do
        checks = ThemeTokens.checks(@theme)
        assert length(checks) == 8 + 30 + 3 + 4 + 4 + 24 + 12
        assert Enum.reject(checks, & &1.pass?) == []
      end

      test "identity marks and brand plate (add-actor-avatars D9)" do
        checks = @theme |> ThemeTokens.checks() |> Enum.filter(&(&1.group == :identity))
        inks = Enum.filter(checks, &(&1.threshold == 4.5))

        assert Enum.map(inks, & &1.bg) ==
                 ["id-plate", "id-squad", "id-neutral"] ++ for(n <- 1..8, do: "id-tint-#{n}")

        assert Enum.all?(inks, &(&1.ratio >= 4.5))

        [edge] = Enum.filter(checks, &(&1.threshold == 3.0))
        assert edge.bg == "surface"
        assert edge.ratio >= 3.0

        assert edge.fg ==
                 if(@theme == "helmsman-dark", do: "id-plate", else: "id-plate-border")
      end

      test "the brand plate is light in both themes" do
        {l, _c, _h, _a} = ThemeTokens.tokens(@theme)["id-plate"]
        assert l >= 0.9
      end

      for {graphic, {graphic_ratio, text_ratio}} <- @semantic[theme] do
        test "#{graphic} graphic and text worst cases" do
          g = unquote(graphic)

          assert_worst(
            @theme,
            &(&1.group == :graphic and &1.fg == g),
            unquote(graphic_ratio),
            3.0
          )

          assert_worst(
            @theme,
            &(&1.group == :text and &1.fg == g <> "-fg"),
            unquote(text_ratio),
            4.5
          )
        end
      end

      test "neutral text worst cases" do
        {muted, subtle, unavailable} = @neutral[@theme]
        assert_worst(@theme, &(&1.fg == "fg-muted"), muted, 4.5)
        assert_worst(@theme, &(&1.group == :subtle), subtle, 3.0)
        assert_worst(@theme, &(&1.group == :unavailable), unavailable, 3.0)
      end

      for {fg, ratio} <- @buttons[theme] do
        test "solid button #{fg}" do
          fg = unquote(fg)
          assert_worst(@theme, &(&1.group == :solid_button and &1.fg == fg), unquote(ratio), 4.5)
        end
      end
    end
  end
end

defmodule HelmsmanWeb.Dev.ThemeTokens do
  @moduledoc """
  Theme tokens parsed from `assets/css/app.css` at compile time, plus WCAG 2.x
  contrast checks for the token combinations required by design D3.

  Colours are converted OKLCH → OKLab → linear sRGB → gamma sRGB (clamped to
  `0..1`). Like browsers, semi-transparent colours and badge backgrounds
  (`color-mix` of a graphic colour into `surface`) are composited in gamma sRGB.
  """

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @external_resource @css_path

  @type token :: {float(), float(), float(), float()}
  @type rgb :: {float(), float(), float()}
  @type check :: %{
          group: :text | :solid_button | :subtle | :unavailable | :graphic | :identity,
          fg: String.t(),
          bg: String.t(),
          ratio: float(),
          threshold: float(),
          pass?: boolean()
        }

  parse_number = fn str ->
    {num, ""} = Float.parse(if String.starts_with?(str, "."), do: "0" <> str, else: str)
    num
  end

  @themes ~r/name:\s*"(helmsman-[a-z]+)";(.*?)\}/s
          |> Regex.scan(File.read!(@css_path), capture: :all_but_first)
          |> Map.new(fn [name, body] ->
            tokens =
              ~r/--hm-([a-z0-9-]+):\s*oklch\(([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+))?\);/
              |> Regex.scan(body, capture: :all_but_first)
              |> Map.new(fn [token | values] ->
                [l, c, h, a] =
                  values |> Enum.concat(["1"]) |> Enum.take(4) |> Enum.map(parse_number)

                {token, {l, c, h, a}}
              end)

            [mix] = Regex.run(~r/--hm-badge-mix:\s*([\d.]+)%;/, body, capture: :all_but_first)
            {name, %{tokens: tokens, badge_mix: parse_number.(mix) / 100}}
          end)

  @theme_names ["helmsman-light", "helmsman-dark"]
  @bg4 ~w(surface canvas hover selected)
  @graphics ~w(brand success warning danger info review)
  @buttons [{"on-brand", "brand"}, {"on-danger", "danger"}, {"on-warning", "warning"}]
  @id_marks ["id-plate", "id-squad", "id-neutral"] ++ for(n <- 1..8, do: "id-tint-#{n}")

  @doc "Theme names defined in `app.css`."
  @spec themes() :: [String.t()]
  def themes, do: @theme_names

  @doc "Map of `--hm-*` token name (without prefix) to `{l, c, h, alpha}`."
  @spec tokens(String.t()) :: %{String.t() => token()}
  def tokens(theme), do: @themes |> Map.fetch!(theme) |> Map.fetch!(:tokens)

  @doc "The `--hm-badge-mix` percentage as a fraction."
  @spec badge_mix(String.t()) :: float()
  def badge_mix(theme), do: @themes |> Map.fetch!(theme) |> Map.fetch!(:badge_mix)

  @doc "Converts OKLCH to gamma-encoded sRGB, each channel clamped to `0..1`."
  @spec oklch_to_srgb(number(), number(), number()) :: rgb()
  def oklch_to_srgb(l, c, h) do
    rad = h * :math.pi() / 180
    a = c * :math.cos(rad)
    b = c * :math.sin(rad)

    lc = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    mc = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    sc = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    {
      gamma(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
      gamma(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
      gamma(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
    }
  end

  defp gamma(x) do
    x = clamp(x)
    clamp(if x <= 0.0031308, do: 12.92 * x, else: 1.055 * :math.pow(x, 1 / 2.4) - 0.055)
  end

  defp clamp(x), do: x |> max(0.0) |> min(1.0)

  @doc "Mixes `p` of `fg` into `bg` in gamma sRGB space."
  @spec mix(rgb(), rgb(), number()) :: rgb()
  def mix({r1, g1, b1}, {r2, g2, b2}, p),
    do: {p * r1 + (1 - p) * r2, p * g1 + (1 - p) * g2, p * b1 + (1 - p) * b2}

  @doc "WCAG 2.x relative luminance of a gamma sRGB colour."
  @spec luminance(rgb()) :: float()
  def luminance({r, g, b}), do: 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)

  defp linear(v) when v <= 0.04045, do: v / 12.92
  defp linear(v), do: :math.pow((v + 0.055) / 1.055, 2.4)

  @doc "WCAG 2.x contrast ratio between two gamma sRGB colours."
  @spec contrast(rgb(), rgb()) :: float()
  def contrast(fg, bg) do
    {lo, hi} = Enum.min_max([luminance(fg), luminance(bg)])
    (hi + 0.05) / (lo + 0.05)
  end

  @doc """
  All contrast checks required by design D3 for `theme`, plus the identity marks of
  add-actor-avatars D9 (group `:identity`): each mark's ink over its fill (4.5), and the
  brand plate against `surface` (3.0) — its fill in the dark theme, its border in the
  light theme.
  """
  @spec checks(String.t()) :: [check()]
  def checks(theme) do
    tokens = tokens(theme)
    color = &rgb(tokens, &1)
    bg4 = Enum.map(@bg4, &{&1, color.(&1)})
    badge = &mix(color.(&1), color.("surface"), badge_mix(theme))

    [
      {:text, 4.5, text_pairs(color, bg4, badge)},
      {:solid_button, 4.5, for({fg, bg} <- @buttons, do: {fg, color.(fg), bg, color.(bg)})},
      {:subtle, 3.0, for({bg, rgb} <- bg4, do: {"fg-subtle", color.("fg-subtle"), bg, rgb})},
      {:unavailable, 3.0,
       for({bg, rgb} <- bg4, do: {"fg 60%", mix(color.("fg"), rgb, 0.6), bg, rgb})},
      {:graphic, 3.0, for(g <- @graphics, {bg, rgb} <- bg4, do: {g, color.(g), bg, rgb})},
      {:identity, 4.5, for(m <- @id_marks, do: {m <> "-ink", color.(m <> "-ink"), m, color.(m)})},
      {:identity, 3.0, [plate_edge(theme, color)]}
    ]
    |> Enum.flat_map(fn {group, threshold, pairs} ->
      for {fg, fg_rgb, bg, bg_rgb} <- pairs do
        ratio = contrast(fg_rgb, bg_rgb)

        %{
          group: group,
          fg: fg,
          bg: bg,
          ratio: ratio,
          threshold: threshold,
          pass?: ratio >= threshold
        }
      end
    end)
  end

  defp plate_edge("helmsman-dark", color),
    do: {"id-plate", color.("id-plate"), "surface", color.("surface")}

  defp plate_edge(_light, color),
    do: {"id-plate-border", color.("id-plate-border"), "surface", color.("surface")}

  defp text_pairs(color, bg4, badge) do
    plain = for fg <- ~w(fg fg-muted), {bg, rgb} <- bg4, do: {fg, color.(fg), bg, rgb}

    semantic =
      for g <- @graphics,
          fg = g <> "-fg",
          {bg, rgb} <- bg4 ++ [{g <> " 徽章底", badge.(g)}],
          do: {fg, color.(fg), bg, rgb}

    plain ++ semantic
  end

  # Opaque colour of a token; semi-transparent tokens are composited over `surface`.
  defp rgb(tokens, name) do
    {l, c, h, a} = Map.fetch!(tokens, name)
    color = oklch_to_srgb(l, c, h)

    if a < 1 do
      {sl, sc, sh, _} = Map.fetch!(tokens, "surface")
      mix(color, oklch_to_srgb(sl, sc, sh), a)
    else
      color
    end
  end
end

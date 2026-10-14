defmodule HelmsmanWeb.Components.Brand do
  @moduledoc """
  Brand icons (add-actor-avatars D1, D17, D18): `brand_icon/1` puts a vendored
  lobe-icons icon on the light brand plate, `model_label/1` shows a model name with the
  icon of its inferred vendor.

  The colour variant (`<name>-color.svg`) is an `<img>` served from
  `priv/static/images/brand/` (some files define gradients with fixed ids, which would
  collide when inlined twice). The monochrome variant is inlined from the file read at
  compile time; only its `width="1em"` / `height="1em"` are replaced by the size class
  and `aria-hidden` is added, so `fill="currentColor"` takes the plate's ink token.
  Unknown keys fall back to a neutral Lucide icon (`bot` for CLIs, `cpu` otherwise).
  """
  use Phoenix.Component
  use HelmsmanWeb, :verified_routes

  import HelmsmanWeb.CoreComponents, only: [icon: 1, tooltip_class: 1]

  alias HelmsmanWeb.Brands

  @dir Path.expand("../../../priv/static/images/brand", __DIR__)

  for name <- Brands.icon_names(),
      suffix <- ["", "-color"],
      do: @external_resource(Path.join(@dir, "#{name}#{suffix}.svg"))

  @mono Map.new(Brands.icon_names(), fn name ->
          "<svg " <> rest = File.read!(Path.join(@dir, "#{name}.svg"))

          rest =
            rest |> String.replace(~s(height="1em" ), "") |> String.replace(~s( width="1em"), "")

          {name, rest}
        end)

  @color Brands.icon_names()
         |> Enum.filter(&File.exists?(Path.join(@dir, "#{&1}-color.svg")))
         |> MapSet.new()

  @doc "Whether `icon` has a vendored colour variant."
  def color?(icon), do: MapSet.member?(@color, icon)

  @doc "Whether `icon` has a vendored (monochrome) file."
  def vendored?(icon), do: Map.has_key?(@mono, icon)

  @plate_sizes %{
    tiny: "size-3.5",
    xs: "size-4",
    sm: "size-5",
    md: "size-7",
    lg: "size-10",
    xl: "size-16"
  }

  @doc "Size class of a mark / plate (`:tiny` 14, `:xs` 16, `:sm` 20, `:md` 28, `:lg` 40, `:xl` 64 px)."
  def size_class(size), do: Map.fetch!(@plate_sizes, size)

  @doc """
  A brand icon on its plate. `icon` is a lobe-icons name (`HelmsmanWeb.Brands`); nil or
  an unknown name renders the neutral `fallback` (`:bot` for CLIs, `:cpu` for vendors and
  platforms). Decorative unless `label` is given (then `role="img"` with that name).
  `shape` `:round` draws a circular plate (a person's built-in icon avatar,
  update-actor-icons D11); the icon keeps 70% of the edge, inside the inscribed square.
  """
  attr :icon, :string, default: nil
  attr :shape, :atom, default: :square, values: [:square, :round]
  attr :fallback, :atom, default: :cpu, values: [:cpu, :bot]
  attr :size, :atom, default: :sm, values: [:tiny, :xs, :sm, :md, :lg, :xl]
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def brand_icon(assigns) do
    icon = if vendored?(assigns.icon), do: assigns.icon
    assigns = assign(assigns, icon: icon, color?: icon && color?(icon))

    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center justify-center overflow-hidden",
        if(@shape == :round, do: "rounded-full", else: "rounded-[25%]"),
        size_class(@size),
        @icon && "border border-id-plate-border bg-id-plate text-id-plate-ink",
        !@icon && "bg-id-neutral text-id-neutral-ink",
        @class
      ]}
      data-brand={@icon || "none"}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={if(@label, do: nil, else: "true")}
    >
      <img
        :if={@color?}
        src={~p"/images/brand/#{@icon <> "-color.svg"}"}
        alt=""
        class="size-[70%]"
        draggable="false"
      />
      {if @icon && !@color?, do: mono(@icon, "size-[70%]")}
      <.icon :if={!@icon} name={fallback_icon(@fallback)} class="size-[70%]" />
    </span>
    """
  end

  defp fallback_icon(:bot), do: "lucide-bot"
  defp fallback_icon(:cpu), do: "lucide-cpu"

  @doc "The inlined monochrome SVG of `icon` with `class` (decorative)."
  def mono(icon, class) do
    Phoenix.HTML.raw(
      ~s(<svg class="#{class}" aria-hidden="true" focusable="false" ) <> Map.fetch!(@mono, icon)
    )
  end

  @doc """
  A model name with its vendor's brand icon (14px plate) and the tooltip
  「<vendor> · <model>」; an unknown vendor shows the neutral chip icon and the bare
  model name. `account_icon` (the bound provider account's icon) applies the family
  override of `HelmsmanWeb.Brands.model_vendor/2`.
  """
  attr :id, :string, default: nil
  attr :model, :string, required: true
  attr :account_icon, :string, default: nil
  attr :mono, :boolean, default: false, doc: "monospace model name"
  attr :class, :any, default: nil

  def model_label(assigns) do
    vendor = Brands.model_vendor(assigns.model, assigns.account_icon)
    name = vendor && Brands.vendor_name(vendor)

    assigns =
      assign(assigns,
        vendor: vendor,
        tip: if(name, do: "#{name} · #{assigns.model}", else: assigns.model),
        vendor_name: name
      )

    ~H"""
    <span
      id={@id}
      class={["hm-tooltip-host relative inline-flex max-w-full items-center gap-1.5", @class]}
      data-model-vendor={@vendor || "none"}
    >
      <.brand_icon icon={@vendor} size={:tiny} label={@vendor_name} />
      <span class={["truncate", @mono && "font-mono"]}>{@model}</span>
      <span aria-hidden="true" class={tooltip_class(:bottom)}>{@tip}</span>
    </span>
    """
  end
end

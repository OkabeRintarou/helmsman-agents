defmodule HelmsmanWeb.PortalHelpers do
  @moduledoc """
  Queries into overlays (side panels, dialogs). They are teleported through
  `<template>` portals that `Phoenix.LiveViewTest.element/3` cannot see into, so these
  helpers render the portal and query its HTML; tests push the overlay's events with
  `render_submit/3` / `render_click/3` (and `with_target/2` for components).
  """

  # Test-only helpers used by web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Phoenix.LiveViewTest

  @doc "The rendered portal of overlay `id` as a LazyHTML tree (empty when absent)."
  def portal(view, id) do
    selector = "##{id}-portal"

    html = if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""

    # The children of <template> live in a separate fragment that selectors do not reach.
    html
    |> String.replace(~r/\A\s*<template[^>]*>/, "")
    |> String.replace(~r/<\/template>\s*\z/, "")
    |> LazyHTML.from_fragment()
  end

  @doc """
  Whether overlay `id` is open: rendered, and neither its root, backdrop nor container is
  hidden — a server-opened overlay must be visible without client JS.
  """
  def open?(view, id) do
    tree = portal(view, id)

    in_portal?(view, id, "##{id}") and
      Enum.all?(["##{id}", "##{id}-backdrop", "##{id}-container"], fn selector ->
        tree |> LazyHTML.query("#{selector}.hidden") |> Enum.empty?()
      end)
  end

  @doc "Whether the portal of `id` has an element matching `selector` (containing `text`)."
  def in_portal?(view, id, selector, text \\ nil) do
    nodes = view |> portal(id) |> LazyHTML.query(selector)

    Enum.any?(nodes, fn node ->
      text == nil or LazyHTML.text(node) =~ text
    end)
  end

  @doc "Text of the elements matching `selector` in the portal of `id`."
  def portal_text(view, id, selector),
    do: view |> portal(id) |> LazyHTML.query(selector) |> LazyHTML.text()

  @doc "The attribute `name` of the first element matching `selector` (or nil)."
  def portal_attr(view, id, selector, name) do
    case view |> portal(id) |> LazyHTML.query(selector) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end
end

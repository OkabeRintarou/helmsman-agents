defmodule HelmsmanWeb.Components.Markdown do
  @moduledoc """
  Display of rendered Markdown (design D1, spec web-markdown): task descriptions,
  feedback and editor previews all use `markdown/1`.

  The container's id carries the anchor namespace and a hash of the content, so new
  content is a new element (the `Mermaid` hook mounts again) while unchanged content
  is left alone by `phx-update="ignore"` (diagrams the hook drew stay in place).
  Typography and colours: `assets/css/markdown.css`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext
  use HelmsmanWeb, :verified_routes

  alias HelmsmanWeb.Markdown

  @doc """
  Renders `content` with `HelmsmanWeb.Markdown.to_html/2`, or shows `html` when given
  (already rendered, e.g. from a cache; `content` still names the element).
  """
  attr :content, :string, required: true
  attr :scope, :map, required: true
  attr :anchor_ns, :string, required: true
  attr :mentions, :list, default: []
  attr :muted_mentions, :map, default: %{}, doc: "see `HelmsmanWeb.Markdown.to_html/2`"
  attr :html, :any, default: nil, doc: "pre-rendered `to_html/2` output for `content`"
  attr :class, :any, default: nil

  def markdown(assigns) do
    rendered =
      assigns.html ||
        Markdown.to_html(assigns.content,
          scope: assigns.scope,
          anchor_ns: assigns.anchor_ns,
          mentions: assigns.mentions,
          muted_mentions: assigns.muted_mentions
        )

    assigns =
      assign(assigns, rendered: rendered, dom_id: dom_id(assigns.anchor_ns, assigns.content))

    ~H"""
    <div
      id={@dom_id}
      class={["hm-prose", @class]}
      phx-hook="Mermaid"
      phx-update="ignore"
      data-mermaid-src={~p"/assets/js/mermaid.js"}
      data-mermaid-label={dgettext("ui", "Mermaid 图表")}
      data-mermaid-failed={dgettext("ui", "图表无法渲染：")}
    >
      {@rendered}
    </div>
    """
  end

  @doc "The id of the container showing `content` under `anchor_ns`."
  @spec dom_id(String.t(), String.t()) :: String.t()
  def dom_id(anchor_ns, content), do: "md-#{anchor_ns}-#{:erlang.phash2(content)}"
end

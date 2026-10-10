defmodule HelmsmanWeb.Components.DataTable do
  @moduledoc """
  Stream-backed table with optional "加载更多" paging.

  * Rows come from a LiveView stream (`rows={@streams.tasks}`), so appending a page or
    `stream_insert/3`-ing one row never re-renders the others.
  * `row_version` (e.g. `& &1.updated_at`) keys a marker element per row; when it
    changes the row briefly flashes (`phx-mounted` + `JS.transition`). Rows rendered
    with the table itself do not flash.
  * Columns marked `secondary` are hidden below the `md` breakpoint.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [button: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :rows, :any, required: true, doc: "a LiveView stream"
  attr :label, :string, required: true, doc: "accessible table caption"
  attr :row_click, :any, default: nil, doc: "fn row -> JS (or event name) for whole-row clicks"
  attr :row_version, :any, default: nil, doc: "fn row -> term; a change flashes the row"
  attr :rich, :boolean, default: false, doc: "44px rows instead of 36px"
  attr :has_more, :boolean, default: false
  attr :load_more, :any, default: nil, doc: "event name or JS for the 加载更多 button"
  attr :class, :any, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :secondary, :boolean
    attr :class, :any
  end

  def data_table(assigns) do
    ~H"""
    <div class={["w-full", @class]}>
      <table class="w-full table-fixed border-collapse text-body">
        <caption class="sr-only">{@label}</caption>
        <thead>
          <tr class="h-8 border-b border-border text-left">
            <th
              :for={col <- @col}
              scope="col"
              class={[
                "px-3 text-caption font-medium text-fg-muted",
                col[:secondary] && "hidden md:table-cell",
                col[:class]
              ]}
            >
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update="stream"
          phx-mounted={JS.set_attribute({"data-ready", ""}, to: "##{@id}")}
        >
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            phx-click={@row_click && @row_click.(row)}
            class={[
              "group border-b border-border hover:bg-hover",
              if(@rich, do: "h-11", else: "h-9"),
              @row_click && "cursor-pointer"
            ]}
          >
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              class={[
                "truncate px-3",
                col[:secondary] && "hidden md:table-cell",
                col[:class]
              ]}
            >
              <span
                :if={i == 0 && @row_version}
                id={"#{dom_id}-v#{:erlang.phash2(@row_version.(row))}"}
                class="hidden"
                phx-mounted={
                  JS.transition("animate-row-flash",
                    to: "##{@id}[data-ready] > ##{dom_id}",
                    time: 600
                  )
                }
              />
              {render_slot(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@has_more} class="flex justify-center py-3">
        <.button id={"#{@id}-more"} size="sm" variant="ghost" phx-click={@load_more}>
          {dgettext("ui", "加载更多")}
        </.button>
      </div>
    </div>
    """
  end
end

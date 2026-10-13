defmodule HelmsmanWeb.CommandPalette do
  @moduledoc """
  The command palette (Ctrl/⌘K), rendered once by `HelmsmanWeb.Layouts.app/1`.

  The selected index lives on the server: the `Hotkeys` hook forwards ↑ ↓ Enter from
  the input as `move` / `execute` events. Results with a `:path` navigate there; results
  with an `:action` are pushed to the client as `hm:palette-action`, which closes the
  palette and performs the action (see `assets/js/app.js`).
  """
  use HelmsmanWeb, :live_component

  alias HelmsmanWeb.CommandPalette.{Actions, Ident, Pages, TaskSearch}
  alias HelmsmanWeb.Components.Overlay

  @dialog_id "command-palette-dialog"

  @doc "Result sources in display order. Feature changes append theirs here."
  def sources, do: [Ident, Pages, TaskSearch, Actions]

  @doc "JS that opens the palette (also used by the sidebar search entry)."
  def open(js \\ %JS{}) do
    js
    |> JS.push("reset", target: "#command-palette")
    |> JS.dispatch("hm:clear-input", to: "##{@dialog_id}-input")
    |> Overlay.open_overlay(@dialog_id, focus: "##{@dialog_id}-input")
  end

  @impl true
  def mount(socket), do: {:ok, assign(socket, query: "", selected: 0)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign_results(socket)}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(query: "", selected: 0) |> assign_results()}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(query: query, selected: 0) |> assign_results()}
  end

  def handle_event("move", %{"delta" => delta}, socket) when is_integer(delta) do
    count = length(socket.assigns.results)
    selected = if count == 0, do: 0, else: Integer.mod(socket.assigns.selected + delta, count)
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("execute", params, socket) do
    index =
      with %{"index" => raw} <- params,
           {index, ""} <- Integer.parse(to_string(raw)) do
        index
      else
        _ -> socket.assigns.selected
      end

    case Enum.at(socket.assigns.results, index) do
      %{path: path} ->
        {:noreply, push_navigate(socket, to: path)}

      %{action: {name, args}} ->
        {:noreply, push_event(socket, "hm:palette-action", Map.put(args, :action, name))}

      nil ->
        {:noreply, socket}
    end
  end

  defp assign_results(socket) do
    scope = socket.assigns[:scope]
    shell = socket.assigns[:shell] || %{}

    ctx = %{
      nav: Map.get(shell, :nav, []),
      recent_tasks: Map.get(shell, :recent_tasks, []),
      can_create_task?: Map.get(shell, :can_create_task?, true)
    }

    query = socket.assigns.query
    results = Enum.flat_map(sources(), & &1.search(scope, query, ctx))
    selected = min(socket.assigns.selected, max(length(results) - 1, 0))
    assign(socket, results: results, selected: selected)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        dialog_id: @dialog_id,
        indexed:
          assigns.results
          |> Enum.with_index()
          |> Enum.chunk_by(fn {result, _} -> result.group end)
      )

    ~H"""
    <div id="command-palette" data-open-palette={open()}>
      <.overlay
        id={@dialog_id}
        labelledby={"#{@dialog_id}-label"}
        focus={"##{@dialog_id}-input"}
        position_class="items-start justify-center px-4 pt-[12vh]"
        container_class="w-full max-w-[560px] rounded-box border border-border overflow-hidden"
        data-hm-palette
      >
        <form
          id={"#{@dialog_id}-form"}
          phx-change="search"
          phx-submit="execute"
          phx-target={@myself}
          class="flex h-12 items-center gap-2 border-b border-border px-3"
        >
          <span id={"#{@dialog_id}-label"} class="sr-only">{dgettext("ui", "命令面板")}</span>
          <.icon name="lucide-search" class="size-4 text-fg-subtle" />
          <input
            id={"#{@dialog_id}-input"}
            name="q"
            value={@query}
            type="text"
            role="combobox"
            autocomplete="off"
            aria-expanded="true"
            aria-controls={"#{@dialog_id}-results"}
            aria-activedescendant={@results != [] && "#{@dialog_id}-result-#{@selected}"}
            data-hm-palette-input
            phx-debounce="80"
            placeholder={dgettext("ui", "输入任务编号、页面或操作…")}
            class="h-full min-w-0 flex-1 bg-transparent text-body text-fg outline-none focus-visible:outline-none"
          />
          <.kbd>Esc</.kbd>
        </form>
        <div
          id={"#{@dialog_id}-results"}
          role="listbox"
          aria-label={dgettext("ui", "结果")}
          class="max-h-[50vh] overflow-y-auto p-1"
        >
          <p :if={@results == []} class="px-3 py-6 text-center text-body text-fg-muted">
            {dgettext("ui", "没有匹配的结果")}
          </p>
          <div :for={group <- @indexed} role="group" aria-label={elem(hd(group), 0).group}>
            <p class="px-2 pt-2 pb-1 text-micro font-medium text-fg-subtle">
              {elem(hd(group), 0).group}
            </p>
            <div
              :for={{result, index} <- group}
              id={"#{@dialog_id}-result-#{index}"}
              role="option"
              aria-selected={to_string(index == @selected)}
              phx-click="execute"
              phx-value-index={index}
              phx-target={@myself}
              class={[
                "flex h-9 cursor-pointer items-center gap-2 rounded-field px-2 text-body",
                if(index == @selected, do: "bg-selected text-fg", else: "text-fg hover:bg-hover")
              ]}
            >
              <.icon name={result[:icon] || "lucide-corner-down-right"} class="size-4 text-fg-muted" />
              <span class="truncate">{result.label}</span>
              <span
                :if={result[:sublabel_html]}
                class="truncate text-caption text-fg-muted [&_mark]:bg-transparent [&_mark]:font-medium [&_mark]:text-fg"
                data-snippet
              >
                {result.sublabel_html}
              </span>
              <span
                :if={!result[:sublabel_html] && result[:sublabel]}
                class="truncate text-caption text-fg-muted"
              >
                {result.sublabel}
              </span>
              <.icon
                :if={index == @selected}
                name="lucide-corner-down-left"
                class="ml-auto size-3.5 text-fg-subtle"
              />
            </div>
          </div>
        </div>
      </.overlay>
    </div>
    """
  end
end

defmodule HelmsmanWeb.MarkdownEditor do
  @moduledoc """
  Markdown editor (design D9, D10, D14; spec web-markdown): a textarea with 编辑 / 预览
  tabs and @ completion, used by the feedback panel, the task description and the
  transition reason.

  The draft belongs to the browser's textarea. The server fills it once per editing
  session (`session`, a number the page increments for every new edit) and never
  rewrites it afterwards: the textarea sits in a `phx-update="ignore"` container whose
  id, like the textarea's, carries the session. The textarea stays in the DOM (hidden)
  in preview mode, so forms submit it and there is never a second field with its name.

  The `Editor` hook asks for the preview with the textarea's current text
  (`set_mode`), queries mentions (`mention_query` / `mention_close`) and, for
  `submit: :event`, sends `save_field` to the page. Events carry the session; those of
  another session are ignored.

  Assigns: `id` (`[a-z0-9-]`, also names the preview's anchor namespace), `session`,
  `scope`, `name` (form field name), `value` (initial text of the session), `label`,
  `errors`, `submit` (`:form` or `:event`), `field` (for `:event`), `rows`,
  `placeholder` and `candidates` (`%{name, kind, owner_name}` of assignable
  identities, humans first).
  """
  use HelmsmanWeb, :live_component

  alias Helmsman.Feedback.Mentions

  @max_mentions 8

  @impl true
  def mount(socket) do
    {:ok, assign(socket, session: nil, mode: :edit, draft: "", mentions: [], mention_q: nil)}
  end

  @impl true
  def update(assigns, socket) do
    new_session? = assigns.session != socket.assigns.session

    socket =
      socket
      |> assign(Map.take(assigns, [:id, :scope, :name, :submit, :session]))
      |> assign(
        label: assigns[:label],
        errors: List.wrap(assigns[:errors]),
        field: assigns[:field],
        rows: assigns[:rows] || 6,
        placeholder: assigns[:placeholder],
        candidates: assigns[:candidates] || [],
        value: assigns[:value] || ""
      )

    socket =
      if new_session?,
        do:
          assign(socket, mode: :edit, draft: socket.assigns.value, mentions: [], mention_q: nil),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode} = params, socket)
      when mode in ~w(edit preview) do
    if current?(socket, params) do
      draft = if is_binary(params["value"]), do: params["value"], else: socket.assigns.draft
      mode = String.to_existing_atom(mode)
      {:noreply, assign(socket, mode: mode, draft: draft, mentions: [], mention_q: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("mention_query", %{"q" => q} = params, socket) when is_binary(q) do
    if current?(socket, params) do
      {:noreply, assign(socket, mentions: complete(socket.assigns.candidates, q), mention_q: q)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("mention_close", params, socket) do
    if current?(socket, params),
      do: {:noreply, assign(socket, mentions: [], mention_q: nil)},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp current?(socket, params), do: session_of(params) == socket.assigns.session

  @doc false
  def session_of(%{"session" => session}) when is_integer(session), do: session

  def session_of(%{"session" => session}) when is_binary(session) do
    case Integer.parse(session) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def session_of(_params), do: nil

  @doc """
  At most #{@max_mentions} candidates whose name, or one of its `/` segments, starts
  with `q` (any case); humans first, then agents, each by name.
  """
  @spec complete([map()], String.t()) :: [map()]
  def complete(candidates, q) do
    q = String.downcase(q)

    candidates
    |> Enum.filter(fn %{name: name} ->
      name = String.downcase(name)

      String.starts_with?(name, q) or
        Enum.any?(String.split(name, "/"), &String.starts_with?(&1, q))
    end)
    |> Enum.sort_by(&{if(to_string(&1.kind) == "human", do: 0, else: 1), &1.name})
    |> Enum.take(@max_mentions)
  end

  @doc """
  The mentions shown in a preview of `draft`: names `Helmsman.Feedback.Mentions`
  finds that are (in any case) names of `candidates`.
  """
  @spec preview_mentions(String.t(), [map()]) :: [String.t()]
  def preview_mentions(draft, candidates) do
    by_name = Map.new(candidates, &{String.downcase(&1.name), &1.name})

    draft
    |> Mentions.extract()
    |> Enum.flat_map(fn candidate ->
      candidate
      |> Mentions.names()
      |> Enum.find_value(&Map.get(by_name, String.downcase(&1)))
      |> List.wrap()
    end)
    |> Enum.uniq()
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        input_id: "#{assigns.id}-input-#{assigns.session}",
        blank?: String.trim(assigns.draft) == ""
      )

    ~H"""
    <div id={@id} data-hm-editor class="flex flex-col gap-1.5">
      <div class="flex items-center justify-between gap-2">
        <label :if={@label} for={@input_id} class="text-label font-medium text-fg">{@label}</label>
        <div
          role="tablist"
          aria-label={dgettext("ui", "编辑方式")}
          class="ml-auto flex items-center gap-0.5 rounded-field bg-hover p-0.5"
        >
          <button
            :for={{mode, text} <- [edit: dgettext("ui", "编辑"), preview: dgettext("ui", "预览")]}
            id={"#{@id}-tab-#{mode}"}
            type="button"
            role="tab"
            aria-selected={to_string(@mode == mode)}
            aria-controls={if(mode == :edit, do: "#{@id}-source", else: "#{@id}-preview")}
            class={[
              "h-6 rounded-badge px-2 text-caption font-medium",
              if(@mode == mode,
                do: "bg-surface text-fg shadow-popover",
                else: "text-fg-muted hover:text-fg"
              )
            ]}
            phx-click={JS.dispatch("hm:editor-mode", to: "##{@input_id}", detail: %{mode: mode})}
          >
            {text}
          </button>
        </div>
      </div>
      <div id={"#{@id}-source"} role="tabpanel" class={["relative", @mode == :preview && "hidden"]}>
        <div id={"#{@id}-source-#{@session}"} phx-update="ignore">
          <textarea
            id={@input_id}
            name={@name}
            rows={@rows}
            placeholder={@placeholder}
            phx-hook="Editor"
            phx-debounce="300"
            data-session={@session}
            data-submit={if(@submit == :form, do: "mod-enter-form", else: "mod-enter")}
            data-field={@field}
            data-editor={@id}
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls={"#{@id}-mentions"}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && "#{@id}-error"}
            class="block w-full resize-y rounded-field border border-border-strong bg-surface px-2 py-1.5 text-body leading-5 text-fg focus:border-brand focus:outline-none"
          >{@value}</textarea>
        </div>
        <ul
          :if={@mentions != []}
          id={"#{@id}-mentions"}
          role="listbox"
          data-q={@mention_q}
          aria-label={dgettext("ui", "提及")}
          class="absolute left-0 top-full z-40 mt-1 flex w-64 flex-col rounded-box border border-border bg-raised p-1 shadow-popover"
        >
          <li
            :for={{actor, i} <- Enum.with_index(@mentions)}
            id={"#{@id}-mention-#{i}"}
            role="option"
            aria-selected={to_string(i == 0)}
            data-name={actor.name}
            class="flex min-h-7 cursor-pointer items-center rounded-field px-1.5 aria-selected:bg-selected hover:bg-hover"
          >
            <.actor_chip actor={actor} />
          </li>
        </ul>
      </div>
      <div
        :if={@mode == :preview}
        id={"#{@id}-preview"}
        role="tabpanel"
        class="min-h-24 rounded-field border border-border bg-surface px-3 py-2"
      >
        <p :if={@blank?} class="text-body text-fg-subtle">{dgettext("ui", "没有内容")}</p>
        <.markdown
          :if={!@blank?}
          content={@draft}
          scope={@scope}
          anchor_ns={"preview-#{@id}"}
          mentions={preview_mentions(@draft, @candidates)}
        />
      </div>
      <input type="hidden" name="editor_session" value={@session} />
      <p
        :for={error <- Enum.take(@errors, 1)}
        id={"#{@id}-error"}
        role="alert"
        class="flex items-center gap-1 text-caption text-danger-fg"
      >
        <.icon name="lucide-circle-alert" class="size-3.5" />{error}
      </p>
    </div>
    """
  end
end

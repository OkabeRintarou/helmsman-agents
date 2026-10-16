defmodule HelmsmanWeb.DesignConversationComponents do
  @moduledoc """
  The frame shared by every kind of design conversation page
  (`HelmsmanWeb.AgentDesignLive`; add-agent-conversation-ui D4, D5, D9, D10;
  add-edit-design-conversations): the two columns (the narrow screen's two
  tabs), the conversation column with its input, and the closed note. Each
  kind brings its own draft column.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]
  import HelmsmanWeb.AgentDesignComponents

  alias HelmsmanWeb.{AgentDesignSquad, AgentDesignTurn, RunLog, Url}
  alias HelmsmanWeb.Components.Menu

  @max_bytes 8192

  @doc "The most bytes of a message."
  def max_bytes, do: @max_bytes

  ## The frame (D9)

  attr :tab, :atom, required: true
  attr :draft_dot?, :boolean, default: false
  attr :draft_label, :string, required: true
  slot :chat, required: true, doc: "the conversation column; gets the class hiding it"
  slot :draft, required: true, doc: "the draft column; gets the class hiding it"

  @doc """
  Two columns on a wide screen, two tabs (「对话」, `draft_label`) on a narrow
  one; the hidden column's class is passed to its slot.
  """
  def design_frame(assigns) do
    ~H"""
    <div id="design" class="flex h-full min-h-0 flex-col">
      <nav
        id="design-tabs"
        aria-label={dgettext("ui", "对话创建")}
        class="flex flex-none items-center gap-4 border-b border-border px-4 lg:hidden"
      >
        <button
          id="design-tab-chat"
          type="button"
          phx-click="tab"
          phx-value-tab="chat"
          aria-current={@tab == :chat && "page"}
          class={tab_class(@tab == :chat)}
        >
          {dgettext("ui", "对话")}
        </button>
        <button
          id="design-tab-draft"
          type="button"
          phx-click="tab"
          phx-value-tab="draft"
          aria-current={@tab == :draft && "page"}
          class={tab_class(@tab == :draft)}
        >
          {@draft_label}
          <span
            :if={@draft_dot?}
            id="design-tab-draft-dot"
            class="size-1.5 rounded-full bg-brand"
            aria-label={dgettext("ui", "有变化")}
          />
        </button>
      </nav>

      <div
        id="design-columns"
        class="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)] lg:grid-cols-[minmax(0,1fr)_minmax(360px,40%)]"
      >
        {render_slot(@chat, @tab != :chat && "max-lg:hidden")}
        {render_slot(@draft, @tab != :draft && "max-lg:hidden")}
      </div>
    </div>
    """
  end

  defp tab_class(active?) do
    [
      "-mb-px inline-flex h-9 items-center gap-1.5 border-b-2 text-body",
      if(active?,
        do: "border-brand font-medium text-fg",
        else: "border-transparent text-fg-muted"
      )
    ]
  end

  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :rows, :string, default: "3"
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :errors, :list, default: []
  attr :hint, :string, default: nil

  @doc """
  The message input with its byte count (D4): Ctrl/⌘+Enter submits (`Editor`),
  Enter is a new line. Its id carries the input generation, so a sent message leaves
  a fresh, empty element.
  """
  def message_box(assigns) do
    assigns = assign(assigns, bytes: byte_size(assigns.message), max: @max_bytes)

    ~H"""
    <div class="flex flex-col gap-1">
      <label for={@id} class="sr-only">{dgettext("ui", "消息")}</label>
      <textarea
        id={@id}
        name="message"
        rows={@rows}
        phx-debounce="300"
        phx-hook="Editor"
        data-submit="mod-enter-form"
        disabled={@disabled}
        placeholder={@placeholder}
        aria-invalid={@errors != [] && "true"}
        class="block max-h-64 w-full resize-y rounded-field border border-border-strong bg-surface px-2 py-1.5 text-body text-fg disabled:opacity-60"
      >{@message}</textarea>
      <div class="flex items-start justify-between gap-2 text-caption">
        <span class="text-fg-muted">{@hint}</span>
        <span
          id={"#{@id}-size"}
          class={[
            "shrink-0 tabular-nums",
            if(@bytes > @max, do: "text-danger-fg", else: "text-fg-muted")
          ]}
          data-over={@bytes > @max && "true"}
        >
          {message_size(@bytes, @max)}
        </span>
      </div>
      <p :for={msg <- @errors} class="text-caption text-danger-fg" data-message-error>{msg}</p>
    </div>
    """
  end

  ## The conversation column (add-agent-conversation-ui D4, D5, D10)

  @doc "The messages, the current turn and the input."

  attr :class, :any, default: nil
  attr :design, :map, required: true
  attr :messages, :any, required: true
  attr :turn, :map, default: nil
  attr :message, :string, required: true
  attr :gen, :integer, required: true
  attr :errors, :list, required: true
  attr :warning, :string, default: nil
  attr :input_reason, :string, default: nil
  attr :helper_items, :list, required: true
  attr :scope, :map, required: true
  attr :appearance, :map, default: %{}

  def chat_column(assigns) do
    helper = assigns.design.helper

    assigns =
      assign(assigns,
        helper: helper,
        helper_warning: helper_reason(helper),
        usage: usage_text(assigns.design.usage),
        bytes: byte_size(assigns.message)
      )

    ~H"""
    <section
      id="design-chat"
      class={["flex min-h-0 min-w-0 flex-col border-border lg:border-r", @class]}
      aria-label={dgettext("ui", "对话")}
    >
      <header class="flex flex-none flex-wrap items-center gap-2 border-b border-border px-4 py-2">
        <span
          id="design-helper"
          class="flex min-w-0 items-center gap-1.5 text-body"
          data-helper={@helper.name}
        >
          <span class="text-fg-muted">{dgettext("ui", "起草：")}</span>
          <.actor_chip actor={helper_actor(@helper, @appearance)} />
          <span class="text-caption text-fg-muted">
            {provider_label(@helper.provider)} · {owner_name(@helper, @scope)}
          </span>
          <span
            :if={@helper_warning}
            class="text-warning-fg"
            title={@helper_warning}
            data-helper-warning
          >
            <.icon name="lucide-triangle-alert" class="size-3.5" />
            <span class="sr-only">{@helper_warning}</span>
          </span>
        </span>
        <.dropdown
          :if={@design.status == :open and @design.current_run == nil}
          id="design-helper-menu"
          label={dgettext("ui", "更换起草 Agent")}
          items={@helper_items}
          popover_class="w-72"
        >
          <:trigger>
            <span class="text-caption font-medium text-fg-muted hover:text-fg">{dgettext("ui", "更换")}</span>
          </:trigger>
        </.dropdown>
        <.button
          :if={@design.status == :open and @design.current_run != nil}
          id="design-helper-change-busy"
          size="xs"
          variant="ghost"
          disabled_reason={dgettext("ui", "等这一轮结束后再更换")}
        >
          {dgettext("ui", "更换")}
        </.button>
        <span class="ml-auto flex items-center gap-3 text-caption text-fg-muted">
          <span id="design-count" class="tabular-nums">{@design.user_messages} / 40</span>
          <span :if={@usage} id="design-usage" class="tabular-nums">{@usage}</span>
        </span>
      </header>

      <div class="relative flex min-h-0 flex-1 flex-col">
        <RunLog.follow_list
          id="design-messages"
          jump_id="design-jump"
          class="px-4 py-4"
          list_class="flex flex-col gap-3"
        >
          <li :for={{dom_id, m} <- @messages} id={dom_id} data-seq={m.seq}>
            <.message message={m} helper={@helper} scope={@scope} appearance={@appearance} />
          </li>
          <:tail>
            <AgentDesignTurn.turn
              :if={@turn}
              turn={@turn}
              helper={@helper.name}
              scope={@scope}
              actor={helper_actor(@helper, @appearance)}
            />
          </:tail>
        </RunLog.follow_list>
      </div>

      <div class="flex-none border-t border-border px-4 py-3">
        <.closed_note :if={@design.status != :open} design={@design} scope={@scope} />
        <div :if={@design.status == :open} class="flex flex-col gap-2">
          <div
            :if={@warning}
            id="design-send-warning"
            role="alert"
            class="flex flex-wrap items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="size-4 shrink-0" />
            <span>{dgettext("ui", "%{helper} 现在不能启动：%{reason}。可以更换起草 Agent",
              helper: @helper.name,
              reason: @warning
            )}</span>
            <.button
              :if={@design.current_run == nil}
              id="design-send-warning-change"
              size="xs"
              phx-click={Menu.open_menu("design-helper-menu")}
            >
              {dgettext("ui", "更换")}
            </.button>
          </div>
          <.form
            for={%{}}
            id="design-send-form"
            phx-change="message_change"
            phx-submit="send"
            class="flex flex-col gap-2"
          >
            <.message_box
              id={"design-message-#{@gen}"}
              message={@message}
              disabled={@input_reason != nil}
              placeholder={@input_reason || dgettext("ui", "继续描述，或回答 AI 的问题")}
              errors={@errors}
              hint={dgettext("ui", "回复会进入 %{helper} 的执行记录，不要粘贴密钥", helper: @helper.name)}
            />
            <div class="flex justify-end">
              <.button
                id="design-send"
                type="submit"
                variant="primary"
                size="sm"
                icon="lucide-send"
                disabled={@input_reason != nil or @bytes > max_bytes() or String.trim(@message) == ""}
                phx-disable-with={dgettext("ui", "正在发送…")}
              >
                {dgettext("ui", "发送")}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  attr :design, :map, required: true
  attr :scope, :map, required: true

  @doc "The note of a closed conversation, with 「开始新的对话」."
  def closed_note(assigns) do
    ~H"""
    <div
      id="design-closed"
      role="status"
      data-status={@design.status}
      class="flex flex-wrap items-center gap-2 rounded-field border border-border bg-surface px-3 py-2 text-body text-fg"
    >
      <span :if={@design.status == :confirmed}>
        {dgettext("ui", "这个对话已确认，创建了")}
        <%= for {a, i} <- Enum.with_index(@design.created_agents) do %>
          <span :if={i > 0}>、</span><.link
            navigate={created_path(@design, @scope.workspace.slug, a.name)}
            class="font-mono font-medium text-brand-fg hover:underline"
            data-created
          >{a.name}</.link>
        <% end %>
      </span>
      <span :if={@design.status == :discarded}>{dgettext("ui", "这个对话已放弃")}</span>
      <span :if={@design.status == :expired}>{dgettext("ui", "这个对话 7 天没有活动，已过期")}</span>
      <.button id="design-new" size="sm" class="ml-auto" phx-click="new_conversation">
        {dgettext("ui", "开始新的对话")}
      </.button>
    </div>
    """
  end

  # A squad conversation created its squad too (D16): that name links to the squad page.
  defp created_path(design, slug, name) do
    squad_name = AgentDesignSquad.squad?(design) && AgentDesignSquad.squad(design.draft)["name"]

    if is_binary(squad_name) and String.downcase(squad_name) == String.downcase(name),
      do: Url.squad_path(slug, name),
      else: Url.agent_path(slug, name)
  end
end

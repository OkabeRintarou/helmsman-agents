defmodule HelmsmanWeb.FeedbackComponents do
  @moduledoc """
  Feedback timeline of the task page (design D4, spec web-feedback): one card per
  thread showing its active record, earlier versions folded underneath, a
  `feedback-<seq>` anchor on every record.

  Events pushed to the page: `open_feedback` with `mode` `add`, `answer` (`target` the
  question's ID) or `revise` (`target` the record's ID).
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.{CollabComponents, FeedbackTimeline, TaskComponents}

  @doc "Display name and badge tone of a feedback kind."
  def kind(kind) do
    case to_string(kind) do
      "comment" -> {dgettext("ui", "评论"), :muted}
      "review" -> {dgettext("ui", "评审"), :review}
      "question" -> {dgettext("ui", "提问"), :warning}
      "answer" -> {dgettext("ui", "回答"), :success}
      other -> {other, :muted}
    end
  end

  @doc "`[{label, value}]` of the kinds one can write."
  def kind_options do
    for kind <- ~w(comment review question answer), do: {elem(kind(kind), 0), kind}
  end

  attr :feedback, :list, required: true
  attr :html, :map, required: true, doc: "%{seq => rendered content}"
  attr :scope, :map, required: true
  attr :revisable, :any, required: true, doc: "MapSet of the IDs the reader may revise"
  attr :can_feedback?, :boolean, required: true
  attr :fresh_after, :integer, default: 0, doc: "records above this number flash when added"
  attr :agents, :map, default: %{}, doc: "see `HelmsmanWeb.TaskComponents.actor_ref/1`"
  attr :appearance, :map, default: %{}, doc: "see `HelmsmanWeb.TaskComponents.actor_ref/1`"
  attr :uri, :string, default: nil, doc: "page URI for the run links of the triggers"

  def timeline(assigns) do
    assigns = assign(assigns, :threads, FeedbackTimeline.threads(assigns.feedback))

    ~H"""
    <section id="feedback" aria-labelledby="feedback-title" class="flex flex-col gap-3">
      <h3 id="feedback-title" class="text-label font-medium text-fg-muted">
        {dgettext("ui", "Feedback")}
        <span :if={@threads != []} class="text-fg-subtle">{length(@threads)}</span>
      </h3>
      <p :if={@threads == []} id="feedback-empty" class="text-body text-fg-subtle">
        {dgettext("ui", "还没有 Feedback")}
      </p>
      <ol id="feedback-threads" class="flex flex-col gap-3">
        <li :for={thread <- @threads} id={"feedback-thread-#{thread.current.thread_seq}"}>
          <.card
            entry={thread.current}
            html={@html[thread.current.seq]}
            scope={@scope}
            revisable?={MapSet.member?(@revisable, thread.current.id)}
            can_feedback?={@can_feedback?}
            fresh?={thread.current.seq > @fresh_after}
            agents={@agents}
            appearance={@appearance}
            uri={@uri}
          />
          <details
            :if={thread.history != []}
            id={"feedback-thread-#{thread.current.thread_seq}-history"}
            phx-mounted={JS.ignore_attributes(["open"])}
            class="group mt-1 ml-4"
          >
            <summary class="cursor-pointer py-1 text-caption text-fg-muted hover:text-fg">
              {dgettext("ui", "早期版本（%{n}）", n: length(thread.history))}
            </summary>
            <div class="mt-1 flex flex-col gap-2">
              <.card
                :for={entry <- thread.history}
                entry={entry}
                html={@html[entry.seq]}
                scope={@scope}
                revisable?={false}
                can_feedback?={false}
                fresh?={false}
                agents={@agents}
                appearance={@appearance}
                uri={@uri}
              />
            </div>
          </details>
        </li>
      </ol>
      <div :if={@can_feedback?}>
        <.button
          id="feedback-add"
          size="sm"
          icon="lucide-message-square-plus"
          phx-click={JS.push("open_feedback", value: %{mode: "add"})}
        >
          {dgettext("ui", "添加 Feedback")}
        </.button>
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :html, :any, default: nil
  attr :scope, :map, required: true
  attr :revisable?, :boolean, default: false
  attr :can_feedback?, :boolean, default: false
  attr :fresh?, :boolean, default: false
  attr :agents, :map, default: %{}, doc: "see `HelmsmanWeb.TaskComponents.actor_ref/1`"
  attr :appearance, :map, default: %{}, doc: "see `HelmsmanWeb.TaskComponents.actor_ref/1`"
  attr :uri, :string, default: nil, doc: "page URI for the run links of the triggers"

  def card(assigns) do
    entry = assigns.entry
    {kind_label, tone} = kind(entry.kind)
    system? = entry.author && entry.author.kind == "system"
    active? = entry.status == "active"

    assigns =
      assign(assigns,
        dom_id: "feedback-#{entry.seq}",
        kind_label: kind_label,
        tone: tone,
        system?: system?,
        active?: active?,
        supersedes: FeedbackTimeline.seq_of(entry.supersedes),
        superseded_by: FeedbackTimeline.seq_of(entry.superseded_by)
      )

    ~H"""
    <article
      id={@dom_id}
      aria-labelledby={"#{@dom_id}-id"}
      data-kind={@entry.kind}
      data-status={@entry.status}
      data-system={@system? && "true"}
      phx-mounted={@fresh? && JS.transition("animate-row-flash", time: 600)}
      class={[
        "scroll-mt-16 rounded-box border border-border px-3 py-2",
        if(@system? or !@active?, do: "bg-canvas", else: "bg-surface")
      ]}
    >
      <header class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <TaskComponents.actor_ref
          actor={@entry.author}
          agents={@agents}
          appearance={@appearance}
          class={@system? && "text-fg-muted"}
        />
        <.badge tone={@tone} data-kind-badge>{@kind_label}</.badge>
        <span class="inline-flex items-center">
          <a
            id={"#{@dom_id}-id"}
            href={"##{@dom_id}"}
            class="font-mono text-label text-fg-muted hover:text-brand-fg"
          >
            {@entry.id}
          </a>
          <.copy_button
            id={"#{@dom_id}-copy"}
            text={@entry.id}
            label={dgettext("ui", "复制 %{id}", id: @entry.id)}
          />
        </span>
        <.relative_time id={"#{@dom_id}-at"} at={@entry.at} class="text-caption text-fg-subtle" />
        <a
          :if={@supersedes}
          href={"#feedback-#{@supersedes}"}
          data-supersedes
          class="text-caption text-fg-muted hover:text-brand-fg"
        >
          {dgettext("ui", "修订自 #%{n}", n: @supersedes)}
        </a>
        <span :if={!@active?} data-superseded class="text-caption text-fg-muted">
          {dgettext("ui", "已作废，被")}
          <a href={"#feedback-#{@superseded_by}"} class="hover:text-brand-fg">#{@superseded_by}</a>
          {dgettext("ui", "取代")}
        </span>
        <.dropdown
          :if={@active? and !@system?}
          id={"#{@dom_id}-menu"}
          label={dgettext("ui", "更多操作")}
          align={:end}
          class="ml-auto"
          trigger_class="h-7 w-7 justify-center"
          items={menu_items(@entry, @revisable?, @dom_id)}
        >
          <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
        </.dropdown>
      </header>
      <.markdown
        content={@entry.content}
        html={@html}
        scope={@scope}
        anchor_ns={"fb-#{@entry.seq}"}
        mentions={@entry.mentions}
        muted_mentions={CollabComponents.mention_notes(@entry[:dispatch])}
        class="mt-1.5"
      />
      <CollabComponents.steer_line entry={@entry} dom_id={@dom_id} />
      <CollabComponents.dispatch_line entry={@entry} dom_id={@dom_id} uri={@uri} />
      <div :if={@active? and @can_feedback? and @entry.kind == "question"} class="mt-2">
        <.button
          id={"#{@dom_id}-answer"}
          size="xs"
          icon="lucide-reply"
          phx-click={JS.push("open_feedback", value: %{mode: "answer", target: @entry.id})}
        >
          {dgettext("ui", "回答")}
        </.button>
      </div>
    </article>
    """
  end

  defp menu_items(entry, revisable?, dom_id) do
    revise =
      if revisable?,
        do: [
          %{
            id: "#{dom_id}-revise",
            label: dgettext("ui", "修订"),
            icon: "lucide-pencil",
            on_select: JS.push("open_feedback", value: %{mode: "revise", target: entry.id})
          }
        ],
        else: []

    revise ++
      [
        %{
          id: "#{dom_id}-copy-link",
          label: dgettext("ui", "复制链接"),
          icon: "lucide-link",
          on_select: JS.dispatch("hm:copy-link", detail: %{anchor: dom_id})
        }
      ]
  end
end

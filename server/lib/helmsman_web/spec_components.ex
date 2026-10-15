defmodule HelmsmanWeb.SpecComponents do
  @moduledoc """
  Components of the task-spec pages (add-spec-workflow-ui D3–D7, D16): badges, the task
  page's 规格 card, the source view with issue markers, the diff, review cards, the
  finalize gate, the home page's to-do list and the audit lines.

  Data are the shapes of `HelmsmanWeb.SpecData` (statuses, verdicts, severities and
  resolutions are atoms).
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.{SpecErrors, Url}

  ## Paths

  @doc "The spec page of task `ident`, with optional query params."
  def spec_path(slug, ident, params \\ %{}) do
    base = "/w/#{slug}/t/#{ident}/spec"
    params = params |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    if params == %{}, do: base, else: Url.put_params(base, params)
  end

  ## Labels

  def status_label(:draft), do: dgettext("ui", "草稿")
  def status_label(:in_review), do: dgettext("ui", "评审中")
  def status_label(:pending_approval), do: dgettext("ui", "待批准")
  def status_label(:finalized), do: dgettext("ui", "已定稿")
  def status_label(:abandoned), do: dgettext("ui", "已放弃")
  def status_label(other), do: to_string(other)

  defp status_tone(:in_review), do: :info
  defp status_tone(:pending_approval), do: :warning
  defp status_tone(:finalized), do: :success
  defp status_tone(:abandoned), do: :subtle
  defp status_tone(_), do: :muted

  def mode_label(:leader), do: dgettext("ui", "Leader 定稿")
  def mode_label(_), do: dgettext("ui", "需要人批准")

  def verdict_label(:pass), do: dgettext("ui", "通过")
  def verdict_label(:fail), do: dgettext("ui", "不通过")
  def verdict_label(:comment), do: dgettext("ui", "意见")
  def verdict_label(other), do: to_string(other)

  defp verdict_tone(:pass), do: :success
  defp verdict_tone(:fail), do: :danger
  defp verdict_tone(_), do: :info

  def severity_label(:P1), do: dgettext("ui", "P1 必须改")
  def severity_label(:P2), do: dgettext("ui", "P2 应该改")
  def severity_label(:P3), do: dgettext("ui", "P3 建议")
  def severity_label(other), do: to_string(other)

  defp severity_tone(:P1), do: :danger
  defp severity_tone(:P2), do: :warning
  defp severity_tone(_), do: :muted

  defp resolution_tone(r) when r in [:open, :disputed], do: :warning
  defp resolution_tone(r) when r in [:accepted, :upheld], do: :info
  defp resolution_tone(_), do: :subtle

  @doc "Whether an issue still needs an answer."
  def unresolved?(%{resolution: r}), do: r in [:open, :disputed]

  def request_label(%{status: :requested}), do: dgettext("ui", "待评审")
  def request_label(%{status: :submitted, review: n}), do: dgettext("ui", "已提交 R%{n}", n: n)
  def request_label(%{status: :lapsed}), do: dgettext("ui", "已过期（评审运行结束时没有提交）")

  def request_label(%{status: :cancelled, close_reason: :superseded}),
    do: dgettext("ui", "已取消（被新版本取代）")

  def request_label(%{status: :cancelled, close_reason: :abandoned}),
    do: dgettext("ui", "已取消（规格已放弃）")

  def request_label(%{status: :cancelled}), do: dgettext("ui", "已取消（被撤回）")
  def request_label(%{status: status}), do: to_string(status)

  def note_kind_label(:reply), do: dgettext("ui", "回复")
  def note_kind_label(:withdraw), do: dgettext("ui", "撤回")
  def note_kind_label(:ruling), do: dgettext("ui", "裁定")
  def note_kind_label(_), do: dgettext("ui", "评论")

  @doc "The text of an audit event."
  def event_text(%{action: action, version: v, data: data}),
    do: event_text(action, v, data || %{})

  defp event_text("created", _v, d), do: dgettext("ui", "建立规格（%{id}）", id: d["change_id"])

  defp event_text("change_id_changed", _v, d),
    do: dgettext("ui", "change_id 改为 %{to}", to: d["to"])

  defp event_text("version_submitted", v, _d), do: dgettext("ui", "提交 v%{v}", v: v)

  defp event_text("review_requested", v, d),
    do: dgettext("ui", "请 %{name} 评审 v%{v}", name: d["reviewer"], v: v)

  defp event_text("review_request_closed", _v, d),
    do: dgettext("ui", "评审请求 #%{n} 结束（%{why}）", n: d["request"], why: close_text(d))

  defp event_text("review_submitted", v, d),
    do: dgettext("ui", "提交评审 R%{n}（v%{v}）", n: d["review"], v: v)

  defp event_text("finalize_proposed", v, _d), do: dgettext("ui", "提议以 v%{v} 定稿", v: v)
  defp event_text("proposal_withdrawn", v, _d), do: dgettext("ui", "撤回 v%{v} 的定稿提议", v: v)
  defp event_text("approved", v, _d), do: dgettext("ui", "批准 v%{v}", v: v)
  defp event_text("finalized", v, _d), do: dgettext("ui", "定稿于 v%{v}", v: v)
  defp event_text("proposal_rejected", v, _d), do: dgettext("ui", "退回 v%{v} 的定稿提议", v: v)
  defp event_text("abandoned", _v, _d), do: dgettext("ui", "放弃")
  defp event_text("reopened", _v, _d), do: dgettext("ui", "重新打开")
  defp event_text(other, _v, _d), do: other

  defp close_text(%{"status" => "lapsed"}), do: dgettext("ui", "过期")
  defp close_text(%{"reason" => "superseded"}), do: dgettext("ui", "被新版本取代")
  defp close_text(%{"reason" => "abandoned"}), do: dgettext("ui", "规格已放弃")
  defp close_text(_), do: dgettext("ui", "被撤回")

  @doc "The quoted text an event carries (a reason or a summary), or nil."
  def event_detail(%{data: data}) when is_map(data), do: data["reason"] || data["summary"]
  def event_detail(_), do: nil

  ## Badges

  attr :status, :atom, required: true
  attr :rest, :global

  def spec_status_badge(assigns) do
    ~H"""
    <.badge tone={status_tone(@status)} data-spec-status={@status} {@rest}>
      {status_label(@status)}
    </.badge>
    """
  end

  attr :verdict, :atom, required: true

  def verdict_badge(assigns) do
    ~H"""
    <.badge tone={verdict_tone(@verdict)} data-verdict={@verdict}>{verdict_label(@verdict)}</.badge>
    """
  end

  attr :severity, :atom, required: true

  def severity_badge(assigns) do
    ~H"""
    <.badge tone={severity_tone(@severity)} data-severity={@severity}>
      {severity_label(@severity)}
    </.badge>
    """
  end

  attr :issue, :map, required: true

  def resolution_badge(assigns) do
    ~H"""
    <.badge tone={resolution_tone(@issue.resolution)} data-resolution={@issue.resolution}>
      {SpecErrors.resolution_label(@issue.resolution)}{fixed_in(@issue)}
    </.badge>
    """
  end

  defp fixed_in(%{resolution: :accepted, notes: notes}) do
    case notes |> Enum.reverse() |> Enum.find(&(&1.resolution == :accepted)) do
      %{fixed_in_version: v} when is_integer(v) -> dgettext("ui", "（在 v%{v} 修改）", v: v)
      _ -> nil
    end
  end

  defp fixed_in(_issue), do: nil

  ## The task page's card

  attr :spec, :map, default: nil, doc: "the summary, or nil"
  attr :epic, :map, default: nil, doc: "`%{ident, spec}` of the task's epic with a spec"
  attr :perms, :map, required: true
  attr :slug, :string, required: true
  attr :ident, :string, required: true
  attr :error, :string, default: nil

  def task_card(assigns) do
    ~H"""
    <section id="task-spec" aria-labelledby="task-spec-title" class="flex flex-col gap-2">
      <div class="flex items-center justify-between gap-2">
        <h2 id="task-spec-title" class="text-label font-medium text-fg-muted">
          {dgettext("ui", "规格")}
        </h2>
        <.link
          :if={@spec}
          id="task-spec-open"
          navigate={spec_path(@slug, @ident)}
          class="text-caption text-fg-muted hover:text-fg hover:underline"
        >
          {dgettext("ui", "打开规格")}
        </.link>
      </div>
      <p :if={@error} id="task-spec-error" role="alert" class="text-caption text-danger-fg">
        {@error}
      </p>
      <div :if={@spec} class="flex flex-col gap-1.5 text-body">
        <div class="flex flex-wrap items-center gap-2">
          <.spec_status_badge status={@spec.status} id="task-spec-status" />
          <code class="truncate font-mono text-caption text-fg-muted" id="task-spec-change-id">
            {@spec.change_id}
          </code>
        </div>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-caption text-fg-muted">
          <span :if={@spec.latest_version == 0} id="task-spec-latest">{dgettext("ui", "还没有版本")}</span>
          <span
            :if={@spec.latest_version > 0}
            id="task-spec-latest"
            data-valid={"#{@spec.latest_valid}"}
          >
            v{@spec.latest_version} {if @spec.latest_valid, do: "✓", else: "✗"}
          </span>
          <span :if={@spec.final_version} id="task-spec-final">
            {dgettext("ui", "定稿 v%{v}", v: @spec.final_version)}
          </span>
          <span id="task-spec-mode">{mode_label(@spec.mode)}</span>
        </div>
        <div
          :if={@spec.pending_reviews != []}
          id="task-spec-pending"
          class="text-caption text-fg-muted"
        >
          {dgettext("ui", "待评审：%{names}",
            names: Enum.map_join(@spec.pending_reviews, "、", & &1.reviewer)
          )}
        </div>
        <div
          :if={@spec.unresolved.p1 + @spec.unresolved.p2 > 0}
          id="task-spec-unresolved"
          class="flex gap-2 text-caption font-medium text-danger-fg"
        >
          <span :if={@spec.unresolved.p1 > 0}>P1 {@spec.unresolved.p1}</span>
          <span :if={@spec.unresolved.p2 > 0}>P2 {@spec.unresolved.p2}</span>
        </div>
        <div
          :if={@spec.proposal}
          id="task-spec-proposal"
          class="flex flex-col gap-1 rounded-field border border-warning tint-warning px-2 py-1.5 text-caption text-warning-fg"
        >
          <span>
            {dgettext("ui", "%{by} 提议 v%{v}", by: @spec.proposal.by, v: @spec.proposal.version)}
          </span>
          <span :if={@spec.proposal.summary} class="line-clamp-2 text-fg-muted">
            {@spec.proposal.summary}
          </span>
          <div :if={@perms.approve or @perms.reject} class="flex gap-2">
            <.button
              :if={@perms.approve}
              id="task-spec-approve"
              size="xs"
              variant="primary"
              navigate={spec_path(@slug, @ident, %{panel: "finalize"})}
            >
              {dgettext("ui", "批准")}
            </.button>
            <.button
              :if={@perms.reject}
              id="task-spec-reject"
              size="xs"
              navigate={spec_path(@slug, @ident, %{panel: "reject"})}
            >
              {dgettext("ui", "退回")}
            </.button>
          </div>
        </div>
      </div>
      <div :if={!@spec} class="flex flex-col gap-1.5 text-caption text-fg-muted">
        <span id="task-spec-none">{dgettext("ui", "这个任务还没有规格")}</span>
        <.link
          :if={@epic}
          id="task-spec-epic"
          navigate={spec_path(@slug, @epic.ident)}
          class="hover:text-fg hover:underline"
        >
          {dgettext("ui", "Epic %{ident} 的规格：%{status} v%{v}",
            ident: @epic.ident,
            status: status_label(@epic.spec.status),
            v: @epic.spec.final_version || @epic.spec.latest_version
          )}
        </.link>
        <div :if={@perms.write}>
          <.button id="task-spec-start" size="xs" icon="lucide-file-plus" phx-click="spec_start">
            {dgettext("ui", "开始规格")}
          </.button>
        </div>
      </div>
    </section>
    """
  end

  ## Source view

  attr :content, :string, required: true
  attr :line, :integer, default: nil
  attr :markers, :map, default: %{}, doc: "`%{line => [issue]}`"
  attr :add_path, :any, default: nil, doc: "fn line -> patch path of 在此行提问题, or nil"
  attr :issue_path, :any, required: true, doc: "fn ref -> path of the issue"
  attr :limit, :integer, default: nil

  def source_view(assigns) do
    lines = String.split(assigns.content, "\n")
    total = length(lines)
    shown = if assigns.limit, do: Enum.take(lines, assigns.limit), else: lines
    assigns = assign(assigns, lines: Enum.with_index(shown, 1), total: total)

    ~H"""
    <div
      id="spec-source"
      phx-hook=".SpecLineScroll"
      data-line={@line}
      class="overflow-x-auto rounded-field border border-border bg-surface font-mono text-caption"
    >
      <div
        :for={{text, n} <- @lines}
        id={"L#{n}"}
        data-line-number={n}
        class={["hm-spec-line group flex min-w-fit", n == @line && "hm-spec-line-target"]}
      >
        <span class="flex w-20 shrink-0 select-none items-center justify-end gap-1 pr-2 text-fg-subtle">
          <.link
            :if={@add_path}
            id={"L#{n}-add"}
            patch={@add_path.(n)}
            class="invisible rounded px-0.5 text-brand group-hover:visible focus:visible"
            title={dgettext("ui", "在此行提问题")}
            aria-label={dgettext("ui", "在第 %{n} 行提问题", n: n)}
          >
            +
          </.link>
          <.link
            :for={issue <- Map.get(@markers, n, [])}
            id={"L#{n}-#{issue.ref}"}
            patch={@issue_path.(issue.ref)}
            data-marker={issue.ref}
            data-severity={issue.severity}
            data-resolved={"#{not unresolved?(issue)}"}
            class={[
              "rounded px-0.5 font-sans text-micro",
              marker_class(issue)
            ]}
            title={issue.body}
          >
            {issue.ref}
          </.link>
          <span>{n}</span>
        </span>
        <span class="whitespace-pre pr-4 text-fg">{text}</span>
      </div>
      <div :if={@limit && @total > @limit} class="border-t border-border px-3 py-2 font-sans">
        <.button id="spec-source-more" size="xs" phx-click="source_more">
          {dgettext("ui", "显示更多（共 %{n} 行）", n: @total)}
        </.button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SpecLineScroll">
      export default {
        mounted() { this.scroll() },
        updated() { this.scroll() },
        scroll() {
          const line = this.el.dataset.line
          if (!line || line === this.done) return
          const row = document.getElementById(`L${line}`)
          // Done only once the row is there: a later part may bring it.
          if (!row) return
          this.done = line
          row.scrollIntoView({block: "center"})
        }
      }
    </script>
    """
  end

  defp marker_class(issue) do
    cond do
      not unresolved?(issue) -> "text-fg-subtle line-through"
      issue.severity == :P1 -> "tint-danger text-danger-fg"
      issue.severity == :P2 -> "tint-warning text-warning-fg"
      true -> "bg-hover text-fg-muted"
    end
  end

  ## Diff

  attr :result, :map, required: true
  attr :links, :any, default: nil, doc: "fn path -> {from_path, to_path} for replaced files"

  def diff(assigns) do
    files = assigns.result.files
    count = fn change -> Enum.count(files, &(&1.change == change)) end

    assigns =
      assign(assigns,
        changed: Enum.reject(files, &(&1.change == :unchanged)),
        unchanged: Enum.filter(files, &(&1.change == :unchanged)),
        counts: %{
          modified: count.(:modified) + count.(:replaced),
          added: count.(:added),
          removed: count.(:removed),
          unchanged: count.(:unchanged)
        }
      )

    ~H"""
    <div id="spec-diff" class="flex flex-col gap-3">
      <p id="spec-diff-summary" class="text-body text-fg-muted">
        {dgettext("ui", "修改 %{m} · 新增 %{a} · 删除 %{r} · 不变 %{u}",
          m: @counts.modified,
          a: @counts.added,
          r: @counts.removed,
          u: @counts.unchanged
        )}
      </p>
      <p
        :if={@result.truncated}
        id="spec-diff-truncated"
        role="alert"
        class="rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        {dgettext("ui", "结果过大已截断")}
      </p>
      <details
        :for={{file, i} <- Enum.with_index(@changed)}
        id={"diff-file-#{i}"}
        data-path={file.path}
        data-change={file.change}
        open
        class="rounded-field border border-border"
      >
        <summary class="flex cursor-pointer items-center gap-2 border-b border-border px-3 py-2 text-body">
          <code class="font-mono text-fg">{file.path}</code>
          <.badge tone={change_tone(file.change)}>{change_label(file.change)}</.badge>
        </summary>
        <p :if={file.change == :replaced} class="px-3 py-2 text-body text-fg-muted" data-replaced>
          {dgettext("ui", "差异计算超时，按整体替换显示（旧 %{a} 行 → 新 %{b} 行）",
            a: Map.get(file, :old_lines, 0),
            b: Map.get(file, :new_lines, 0)
          )}
        </p>
        <div :if={file.change != :replaced} class="overflow-x-auto font-mono text-caption">
          <div :for={hunk <- file.hunks} class="border-b border-border last:border-b-0">
            <div class="bg-hover px-3 py-0.5 text-fg-subtle">
              @@ -{hunk.old_start},{hunk.old_lines} +{hunk.new_start},{hunk.new_lines} @@
            </div>
            <div
              :for={{op, text, old_n, new_n} <- numbered(hunk)}
              class={["flex min-w-fit", line_class(op)]}
              data-op={op}
            >
              <span class="w-10 shrink-0 select-none pr-1 text-right text-fg-subtle">{old_n}</span>
              <span class="w-10 shrink-0 select-none pr-1 text-right text-fg-subtle">{new_n}</span>
              <span class="w-4 shrink-0 select-none text-center">{op_mark(op)}</span>
              <span class="whitespace-pre pr-4">{text}</span>
            </div>
          </div>
        </div>
      </details>
      <p :if={@unchanged != []} id="spec-diff-unchanged" class="text-caption text-fg-muted">
        {dgettext("ui", "不变：%{paths}", paths: Enum.map_join(@unchanged, "、", & &1.path))}
      </p>
    </div>
    """
  end

  defp numbered(hunk) do
    {rows, _} =
      Enum.map_reduce(hunk.lines, {hunk.old_start, hunk.new_start}, fn {op, text}, {o, n} ->
        case op do
          :eq -> {{op, text, o, n}, {o + 1, n + 1}}
          :del -> {{op, text, o, nil}, {o + 1, n}}
          :ins -> {{op, text, nil, n}, {o, n + 1}}
        end
      end)

    rows
  end

  defp op_mark(:del), do: "-"
  defp op_mark(:ins), do: "+"
  defp op_mark(_), do: " "

  defp line_class(:del), do: "tint-danger text-danger-fg"
  defp line_class(:ins), do: "tint-success text-success-fg"
  defp line_class(_), do: "text-fg"

  def change_label(:added), do: dgettext("ui", "新增")
  def change_label(:removed), do: dgettext("ui", "删除")
  def change_label(:modified), do: dgettext("ui", "修改")
  def change_label(:replaced), do: dgettext("ui", "整体替换")
  def change_label(_), do: dgettext("ui", "不变")

  defp change_tone(:added), do: :success
  defp change_tone(:removed), do: :danger
  defp change_tone(_), do: :info

  ## Reviews

  attr :review, :map, required: true
  attr :latest, :integer, required: true
  attr :scope, :map, required: true
  attr :actions, :any, required: true, doc: "fn issue -> [{kind, label}] of the issue's buttons"
  attr :note_path, :any, required: true, doc: "fn ref, kind -> patch path"
  attr :file_path, :any, required: true, doc: "fn version, file, line -> patch path"
  attr :highlight, :string, default: nil

  def review_card(assigns) do
    ~H"""
    <article
      id={"review-R#{@review.number}"}
      class="flex flex-col gap-2 rounded-field border border-border p-3"
    >
      <header class="flex flex-wrap items-center gap-2 text-body">
        <span class="font-mono font-medium text-fg">R{@review.number}</span>
        <span class="text-fg" data-reviewer>{@review.reviewer}</span>
        <.verdict_badge verdict={@review.verdict} />
        <span :if={@review.version != @latest} class="text-caption text-fg-muted" data-for-version>
          {dgettext("ui", "针对 v%{v}", v: @review.version)}
        </span>
        <.relative_time
          id={"review-R#{@review.number}-at"}
          at={@review.at}
          class="text-caption text-fg-subtle"
        />
      </header>
      <.markdown
        :if={@review.summary not in [nil, ""]}
        content={@review.summary}
        scope={@scope}
        anchor_ns={"spec-r#{@review.number}"}
      />
      <ol class="flex flex-col gap-2">
        <li
          :for={issue <- @review.issues}
          id={"issue-" <> String.replace(issue.ref, ".", "-")}
          data-ref={issue.ref}
          class={[
            "flex flex-col gap-1.5 rounded-field border border-border px-3 py-2",
            @highlight == issue.ref && "ring-2 ring-brand"
          ]}
        >
          <div class="flex flex-wrap items-center gap-2 text-body">
            <span class="font-mono text-fg">{issue.ref}</span>
            <.severity_badge severity={issue.severity} />
            <.resolution_badge issue={issue} />
            <.link
              :if={issue.file}
              patch={@file_path.(@review.version, issue.file, issue.line)}
              class="font-mono text-caption text-fg-muted hover:underline"
              data-location
            >
              {issue.file}{if issue.line, do: ":#{issue.line}"}{if issue.anchor,
                do: " · #{issue.anchor}"}
            </.link>
          </div>
          <.markdown content={issue.body} scope={@scope} anchor_ns={"spec-#{slug(issue.ref)}"} />
          <div :if={issue.suggestion not in [nil, ""]} class="text-body text-fg-muted" data-suggestion>
            <span class="text-caption font-medium">{dgettext("ui", "建议")}</span>
            <.markdown
              content={issue.suggestion}
              scope={@scope}
              anchor_ns={"spec-#{slug(issue.ref)}-s"}
            />
          </div>
          <ul :if={issue.notes != []} class="flex flex-col gap-1 border-l-2 border-border pl-3">
            <li :for={note <- issue.notes} class="text-body" data-note={note.n}>
              <div class="flex flex-wrap items-center gap-2 text-caption text-fg-muted">
                <span class="text-fg">{note.author}</span>
                <span data-note-kind={note.kind}>{note_kind_label(note.kind)}</span>
                <span :if={note.resolution} data-note-resolution={note.resolution}>
                  → {SpecErrors.resolution_label(note.resolution)}
                </span>
                <.relative_time
                  id={"note-#{slug(issue.ref)}-#{note.n}"}
                  at={note.at}
                  class="text-fg-subtle"
                />
              </div>
              <p :if={note.body not in [nil, ""]} class="whitespace-pre-wrap text-fg">{note.body}</p>
            </li>
          </ul>
          <div :if={@actions.(issue) != []} class="flex flex-wrap gap-2">
            <.button
              :for={{kind, label} <- @actions.(issue)}
              id={"issue-#{slug(issue.ref)}-#{kind}"}
              size="xs"
              patch={@note_path.(issue.ref, kind)}
            >
              {label}
            </.button>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  defp slug(ref), do: ref |> String.downcase() |> String.replace(".", "-")

  ## Gate

  attr :gate, :list, required: true, doc: "`[%{id, ok, text, detail}]`"
  attr :id, :string, default: "spec-gate"

  def gate(assigns) do
    ~H"""
    <ul id={@id} class="flex flex-col gap-1 text-body">
      <li
        :for={item <- @gate}
        id={"#{@id}-#{item.id}"}
        data-ok={"#{item.ok}"}
        class="flex items-start gap-2"
      >
        <.icon
          name={if(item.ok, do: "lucide-circle-check", else: "lucide-circle-x")}
          class={["mt-0.5 size-4 shrink-0", if(item.ok, do: "text-success", else: "text-danger")]}
        />
        <span class="flex flex-col">
          <span class="text-fg">{item.text}</span>
          <span
            :if={!item.ok and item.detail != []}
            class="flex flex-wrap gap-1 text-caption text-fg-muted"
          >
            <%= for {label, path} <- item.detail do %>
              <.link :if={path} patch={path} class="hover:underline" data-gate-link>{label}</.link>
              <span :if={!path}>{label}</span>
            <% end %>
          </span>
        </span>
      </li>
    </ul>
    """
  end

  @doc """
  The finalize gate as items for `gate/1`: the latest version valid, no unresolved
  P1 / P2 (`refs`) and no pending review on the latest version. `issue_path` links the
  refs.
  """
  def gate_items(spec, refs, issue_path) do
    pending = for r <- spec.pending_reviews, r.version == spec.latest_version, do: r.reviewer

    [
      %{
        id: "valid",
        ok: spec.latest_valid == true,
        text: dgettext("ui", "最新版本校验通过"),
        detail: []
      },
      %{
        id: "issues",
        ok: refs == [],
        text: dgettext("ui", "没有未解决的 P1 / P2"),
        detail: Enum.map(refs, &{&1, issue_path.(&1)})
      },
      %{
        id: "reviews",
        ok: pending == [],
        text: dgettext("ui", "最新版本没有待完成的评审"),
        detail: Enum.map(pending, &{&1, nil})
      }
    ]
  end

  ## Home page

  attr :attention, :map, required: true
  attr :slug, :string, required: true

  def attention(assigns) do
    ~H"""
    <section
      :if={@attention.pending_approval != [] or @attention.review_requests != []}
      id="spec-attention"
      aria-labelledby="spec-attention-title"
      class="flex flex-col gap-3"
    >
      <h2 id="spec-attention-title" class="text-heading font-semibold text-fg">
        {dgettext("ui", "待处理的规格")}
      </h2>
      <div
        :if={@attention.pending_approval != []}
        id="spec-attention-approve"
        class="flex flex-col gap-1"
      >
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "待你批准")}</h3>
        <.link
          :for={item <- @attention.pending_approval}
          id={"spec-attention-approve-#{item.task}"}
          navigate={spec_path(@slug, item.task, %{panel: "finalize"})}
          class="flex items-center gap-2 rounded-field px-2 py-1.5 text-body hover:bg-hover"
        >
          <span class="font-mono text-fg-muted">{item.task}</span>
          <span class="min-w-0 flex-1 truncate text-fg">{item.title}</span>
          <span class="text-caption text-fg-muted">v{item.version} · {item.proposed_by}</span>
          <.relative_time
            id={"spec-attention-approve-#{item.task}-at"}
            at={item.at}
            class="text-caption text-fg-subtle"
          />
        </.link>
      </div>
      <div
        :if={@attention.review_requests != []}
        id="spec-attention-review"
        class="flex flex-col gap-1"
      >
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "请你评审")}</h3>
        <.link
          :for={item <- @attention.review_requests}
          id={"spec-attention-review-#{item.task}"}
          navigate={spec_path(@slug, item.task, %{panel: "review"})}
          class="flex items-center gap-2 rounded-field px-2 py-1.5 text-body hover:bg-hover"
        >
          <span class="font-mono text-fg-muted">{item.task}</span>
          <span class="min-w-0 flex-1 truncate text-fg">{item.title}</span>
          <span class="text-caption text-fg-muted">v{item.version} · {item.requested_by}</span>
          <.relative_time
            id={"spec-attention-review-#{item.task}-at"}
            at={item.at}
            class="text-caption text-fg-subtle"
          />
        </.link>
      </div>
    </section>
    """
  end
end

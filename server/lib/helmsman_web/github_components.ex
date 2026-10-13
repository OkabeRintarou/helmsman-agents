defmodule HelmsmanWeb.GitHubComponents do
  @moduledoc """
  GitHub visuals shared by the pages (add-github-ui D2): the repository chip of project
  headers and cards, the 拉取请求 card of the task page with its verdict and reason texts
  (D8, D9), and the merge preview of the 验收 panel (D11).
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.Components.Status

  @web_url "https://github.com"

  @doc "The GitHub page of the repository `full_name` (`owner/name`)."
  def repository_url(full_name), do: "#{@web_url}/#{full_name}"

  @doc """
  The bound repository of a project: `git-branch` icon, `owner/name` (a link to GitHub
  unless `link={false}`, e.g. inside a card that is itself a link), an optional
  `→ <branch>`, and a warning mark when the repository is unavailable.
  """
  attr :id, :string, required: true
  attr :repository, :map, required: true, doc: "`%{full_name, available}`"
  attr :branch, :string, default: nil
  attr :link, :boolean, default: true
  attr :class, :any, default: nil

  def repo_chip(assigns) do
    ~H"""
    <span
      id={@id}
      data-available={to_string(@repository.available)}
      class={["inline-flex min-w-0 items-center gap-1 text-caption text-fg-muted", @class]}
    >
      <.icon name="lucide-git-branch" class="size-3.5 flex-none" />
      <a
        :if={@link}
        href={repository_url(@repository.full_name)}
        target="_blank"
        rel="noopener noreferrer"
        class="truncate font-mono hover:text-fg hover:underline"
        data-repository
      >
        {@repository.full_name}
      </a>
      <span :if={!@link} class="truncate font-mono" data-repository>{@repository.full_name}</span>
      <span :if={@branch} class="flex-none" data-branch>
        → <span class="font-mono">{@branch}</span>
      </span>
      <.tooltip
        :if={!@repository.available}
        id={"#{@id}-unavailable"}
        text={dgettext("ui", "仓库不可用，不会开 PR 或合并")}
        class="flex-none"
      >
        <.icon
          name="lucide-triangle-alert"
          class="size-3.5 text-warning"
          label={dgettext("ui", "仓库不可用")}
          data-unavailable
        />
      </.tooltip>
    </span>
    """
  end

  ## Pull request card (D8, D9)

  @doc "The first 7 characters of a commit SHA (nil stays nil)."
  def short_sha(nil), do: nil
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  @doc "`owner/name#number` of a pull request view."
  def pr_ref(%{repository: %{full_name: full_name}, number: number}),
    do: "#{full_name}##{number}"

  @doc "The identity of a pull request view (repository and number, D10), or nil."
  def pr_key(nil), do: nil
  def pr_key(%{repository: %{full_name: full_name}, number: number}), do: {full_name, number}

  @doc "Icon, tone and name of a pull request state."
  def pr_state("draft"),
    do: %{icon: "lucide-git-pull-request-draft", tone: :muted, label: dgettext("ui", "草稿")}

  def pr_state("open"),
    do: %{icon: "lucide-git-pull-request", tone: :success, label: dgettext("ui", "可评审")}

  def pr_state("merged"),
    do: %{icon: "lucide-git-merge", tone: :review, label: dgettext("ui", "已合并")}

  def pr_state("closed"),
    do: %{icon: "lucide-git-pull-request-closed", tone: :danger, label: dgettext("ui", "已关闭")}

  def pr_state(other),
    do: %{icon: "lucide-git-pull-request", tone: :muted, label: to_string(other)}

  @doc "Tone and name of a CI state (`checks_state`)."
  def checks_badge("pending"), do: {:info, dgettext("ui", "进行中")}
  def checks_badge("success"), do: {:success, dgettext("ui", "通过")}
  def checks_badge("failure"), do: {:danger, dgettext("ui", "失败")}
  def checks_badge(_none), do: {:muted, dgettext("ui", "无检查")}

  @max_failed 5

  @doc """
  The check summary of the pull request's head (R5): nil unless `checks` was read for
  the current head; else `%{passed, total, pending, failed, more}` with at most
  #{@max_failed} failed names and `more` the failed checks not named.
  """
  def checks_summary(%{checks: %{head_sha: head} = checks, head_sha: head})
      when is_binary(head) do
    total = checks.total || 0
    passed = checks.passed || 0
    pending = checks.pending || 0
    failed = Enum.take(checks.failed || [], @max_failed)
    failing = total - passed - pending

    %{
      passed: passed,
      total: total,
      pending: pending,
      failed: failed,
      more: if(failing > length(failed), do: failing - length(failed), else: 0)
    }
  end

  def checks_summary(_pr), do: nil

  @doc """
  The one-line verdict of a pull request (D9): `%{tone, label, text, at, unknown}`.
  `at` is a time shown relative after the text (merged); `unknown` is a reason code the
  page does not know (the text is then GitHub's `merge_note`).
  """
  def verdict(pr, task_status, now \\ DateTime.utc_now())

  def verdict(%{state: "merged"} = pr, _task_status, _now) do
    result(:review, dgettext("ui", "已合并"),
      text: dgettext("ui", "已合并到 %{branch}", branch: pr.base_branch),
      at: pr.merged_at
    )
  end

  def verdict(%{state: "closed"} = pr, _task_status, _now) do
    text =
      if pr.merge_reason == "pr_closed",
        do: reason_text("pr_closed", pr),
        else: dgettext("ui", "PR 已关闭")

    result(:danger, dgettext("ui", "已关闭"), text: text)
  end

  def verdict(%{merge_status: "waiting"} = pr, _task_status, now) do
    text =
      case pr.merge_reason do
        "ci_pending" -> ci_pending_text(pr.waiting_since, now)
        "run_active" -> dgettext("ui", "等待运行结束后合并")
        "required_checks" -> dgettext("ui", "等待分支保护要求的检查")
        _ -> nil
      end

    with_reason(result(:info, dgettext("ui", "等待中"), text: text), pr, text)
  end

  def verdict(%{merge_status: "stale"}, _task_status, _now) do
    result(:warning, dgettext("ui", "验收后有新提交"), text: dgettext("ui", "验收后分支上有新提交，需要按当前提交重新验收"))
  end

  def verdict(%{merge_status: "blocked"} = pr, _task_status, _now) do
    text = reason_text(pr.merge_reason, pr)
    with_reason(result(:danger, dgettext("ui", "已阻止"), text: text), pr, text)
  end

  def verdict(%{merge_status: "failed"} = pr, _task_status, _now) do
    text =
      case pr.merge_reason do
        "ci_failed_limit" ->
          dgettext("ui", "已自动重开 %{n} 次仍然 CI 失败，需要人处理", n: pr.auto_reopen_count)

        "merge_conflict_limit" ->
          dgettext("ui", "已自动重开 %{n} 次仍有合并冲突，需要人处理", n: pr.auto_reopen_count)

        _ ->
          nil
      end

    with_reason(result(:danger, dgettext("ui", "需要人处理"), text: text), pr, text)
  end

  def verdict(%{merge_status: "none", merge_reason: "policy_manual"}, _task_status, _now) do
    result(:muted, dgettext("ui", "手动合并"), text: dgettext("ui", "项目设置为不自动合并：在 GitHub 上合并，或点立即合并"))
  end

  def verdict(%{state: "draft"}, _task_status, _now),
    do: result(:muted, dgettext("ui", "草稿"), text: dgettext("ui", "任务完成后转为可评审"))

  def verdict(_pr, "verified", _now), do: result(:info, dgettext("ui", "等待合并检查"))
  def verdict(_pr, _task_status, _now), do: result(:muted, dgettext("ui", "等待验收"))

  defp result(tone, label, opts \\ []) do
    %{
      tone: tone,
      label: label,
      text: Keyword.get(opts, :text),
      at: Keyword.get(opts, :at),
      unknown: nil
    }
  end

  # A reason the page has no text for: GitHub's English note, marked unknown.
  defp with_reason(verdict, _pr, text) when is_binary(text), do: verdict

  defp with_reason(verdict, pr, nil),
    do: %{verdict | text: pr.merge_note, unknown: pr.merge_reason}

  defp ci_pending_text(nil, _now), do: dgettext("ui", "等待 CI")

  defp ci_pending_text(since, now),
    do: dgettext("ui", "等待 CI · 已等待 %{duration}", duration: duration_text(since, now))

  @doc "A duration since `since` in whole minutes, hours or days (at least 1 minute)."
  def duration_text(%DateTime{} = since, %DateTime{} = now) do
    secs = max(DateTime.diff(now, since, :second), 0)

    cond do
      secs < 3600 -> dgettext("ui", "%{n} 分钟", n: max(div(secs, 60), 1))
      secs < 86_400 -> dgettext("ui", "%{n} 小时", n: div(secs, 3600))
      true -> dgettext("ui", "%{n} 天", n: div(secs, 86_400))
    end
  end

  @doc "Chinese text of a `blocked` reason code (D9), or nil for codes the page does not know."
  def reason_text("agent_verified", _pr), do: dgettext("ui", "由 Agent 验收；项目要求人验收后才自动合并")

  def reason_text("not_independent", _pr),
    do: dgettext("ui", "验收不独立：验收人参与了这份代码（出处或触发链上），或是执行方自验收")

  def reason_text("verified_sha_missing", _pr),
    do: dgettext("ui", "这次验收没有记下提交，可按当前提交重新验收")

  def reason_text("verified_sha_not_pushed", _pr),
    do:
      dgettext(
        "ui",
        "被验收的提交不是 Helmsman 运行推送到当前仓库的，可按当前提交重新验收，或在 GitHub 上合并"
      )

  def reason_text("push_chain_broken", _pr),
    do: dgettext("ui", "分支上有不是 Helmsman 运行推送的提交，需要在 GitHub 上合并")

  def reason_text("ci_timeout", _pr), do: dgettext("ui", "CI 6 小时内没有结果；处理后点重试")

  def reason_text("merge_rejected", _pr),
    do: dgettext("ui", "GitHub 拒绝合并（分支保护等），需要在 GitHub 上处理")

  def reason_text("pr_closed", _pr),
    do: dgettext("ui", "PR 在 GitHub 上被关闭，需要在 GitHub 上重新打开")

  def reason_text("repository_unavailable", _pr),
    do: dgettext("ui", "仓库不可用（安装已断开或仓库移出范围）")

  def reason_text("branch_missing", _pr), do: dgettext("ui", "任务分支在 GitHub 上不存在，无法开 PR")
  def reason_text(_code, _pr), do: nil

  @doc """
  The 拉取请求 card of the task page (D8). Not rendered when the project has no GitHub
  repository and the task has no pull request.

  * `repository`: the project's bound repository (`%{full_name, available}`) or nil;
  * `busy`: the kind of the operation in progress (D10), which disables the actions;
  * `reverify`: whether 按当前提交重新验收 is offered (`can.reverify` and no active run).
  """
  attr :pr, :map, default: nil
  attr :repository, :map, default: nil
  attr :task_status, :string, required: true
  attr :busy, :atom, default: nil
  attr :reverify, :boolean, default: false
  attr :retried, :boolean, default: false
  attr :now, DateTime, default: nil

  def pr_card(%{pr: nil, repository: nil} = assigns), do: ~H""

  def pr_card(assigns) do
    ~H"""
    <section id="task-pr" aria-labelledby="task-pr-title">
      <h2 id="task-pr-title" class="mb-2 text-label font-medium text-fg-muted">
        {dgettext("ui", "拉取请求")}
      </h2>
      <.no_pr :if={@pr == nil} repository={@repository} />
      <.pr_body
        :if={@pr}
        pr={@pr}
        task_status={@task_status}
        busy={@busy}
        reverify={@reverify}
        retried={@retried}
        now={@now || DateTime.utc_now()}
      />
    </section>
    """
  end

  attr :repository, :map, required: true

  defp no_pr(%{repository: %{available: false}} = assigns) do
    ~H"""
    <p
      id="task-pr-empty"
      class="flex items-start gap-1.5 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
    >
      <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 flex-none" />
      <span>
        {dgettext("ui", "仓库 %{repository} 不可用，不会开 PR", repository: @repository.full_name)}
      </span>
    </p>
    """
  end

  defp no_pr(assigns) do
    ~H"""
    <p id="task-pr-empty" class="text-body text-fg-muted">
      {dgettext("ui", "还没有 PR。Agent 推送提交后会自动创建草稿 PR。")}
    </p>
    """
  end

  attr :pr, :map, required: true
  attr :task_status, :string, required: true
  attr :busy, :atom, default: nil
  attr :reverify, :boolean, default: false
  attr :retried, :boolean, default: false
  attr :now, DateTime, required: true

  defp pr_body(assigns) do
    pr = assigns.pr
    {checks_tone, checks_label} = checks_badge(pr.checks_state)
    {graphic, _text, _tint} = Status.tone_classes(pr_state(pr.state).tone)

    assigns =
      assign(assigns,
        state: pr_state(pr.state),
        state_color: graphic,
        verdict: verdict(pr, assigns.task_status, assigns.now),
        checks_tone: checks_tone,
        checks_label: checks_label,
        summary: checks_summary(pr),
        stale_verified?: pr.verified_sha != nil and pr.verified_sha != pr.head_sha,
        retry?: pr.can.retry and pr.merge_status in ~w(blocked failed),
        request_at: parse_time(pr.merge_request && pr.merge_request.at)
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex min-w-0 items-center gap-1.5 text-body">
        <span id="task-pr-state" data-state={@pr.state} class="inline-flex items-center gap-1">
          <.icon name={@state.icon} class={["size-4", @state_color]} />
          <span class="font-medium text-fg">{@state.label}</span>
        </span>
        <a
          id="task-pr-link"
          href={@pr.url}
          target="_blank"
          rel="noopener noreferrer"
          class="font-mono text-label text-fg-muted hover:text-brand-fg hover:underline"
        >
          #{@pr.number}
        </a>
        <span
          id="task-pr-repository"
          class="ml-auto min-w-0 truncate font-mono text-caption text-fg-muted"
          title={@pr.repository.full_name}
        >
          {@pr.repository.full_name}
        </span>
      </div>
      <div id="task-pr-verdict" class="flex flex-col gap-1" data-tone={@verdict.tone}>
        <div class="flex flex-wrap items-center gap-1.5 text-body">
          <.badge tone={@verdict.tone} data-verdict>{@verdict.label}</.badge>
          <span
            :if={@verdict.text}
            data-verdict-text
            class={["text-fg-muted", @verdict.unknown && "whitespace-pre-wrap break-words"]}
          >
            {@verdict.text}
          </span>
          <.relative_time
            :if={@verdict.at}
            id="task-pr-verdict-at"
            at={@verdict.at}
            now={@now}
            class="text-caption text-fg-subtle"
          />
        </div>
        <details
          :if={@pr.merge_reason == "merge_rejected" and @pr.merge_note not in [nil, ""]}
          id="task-pr-note"
          class="text-caption"
        >
          <summary class="cursor-pointer text-fg-muted hover:text-fg">
            {dgettext("ui", "GitHub 的说明")}
          </summary>
          <p class="mt-1 whitespace-pre-wrap break-words text-fg" phx-no-format>{@pr.merge_note}</p>
        </details>
      </div>
      <.property_list>
        <.property_row label={dgettext("ui", "分支")} id="task-pr-branch">
          <span class="min-w-0 truncate font-mono text-label" title={@pr.branch}>{@pr.branch}</span>
          <.copy_button
            id="task-pr-branch-copy"
            text={@pr.branch}
            label={dgettext("ui", "复制分支名")}
          />
          <span class="flex-none text-fg-subtle">→</span>
          <span class="flex-none font-mono text-label">{@pr.base_branch}</span>
        </.property_row>
        <.property_row label={dgettext("ui", "CI")} id="task-pr-checks">
          <div class="flex min-w-0 flex-col gap-1 py-1">
            <span class="flex flex-wrap items-center gap-1.5">
              <.badge tone={@checks_tone} data-checks={@pr.checks_state}>{@checks_label}</.badge>
              <span :if={@summary} data-checks-passed class="text-caption text-fg-muted">
                {dgettext("ui", "%{passed}/%{total} 通过",
                  passed: @summary.passed,
                  total: @summary.total
                )}
              </span>
              <span
                :if={@summary && @summary.pending > 0}
                data-checks-pending
                class="text-caption text-fg-muted"
              >
                {dgettext("ui", "%{n} 进行中", n: @summary.pending)}
              </span>
            </span>
            <ul
              :if={@summary && @pr.checks_state == "failure" && @summary.failed != []}
              id="task-pr-failed-checks"
              class="flex flex-col text-caption text-danger-fg"
            >
              <li :for={name <- @summary.failed} class="truncate font-mono" title={name}>{name}</li>
              <li :if={@summary.more > 0} data-more class="text-fg-muted">
                {dgettext("ui", "等 %{n} 个", n: @summary.more)}
              </li>
            </ul>
          </div>
        </.property_row>
        <.property_row :if={@pr.head_sha} label={dgettext("ui", "头部")} id="task-pr-head">
          <code class="font-mono text-label text-fg-muted" title={@pr.head_sha}>
            {short_sha(@pr.head_sha)}
          </code>
        </.property_row>
        <.property_row :if={@pr.verified_sha} label={dgettext("ui", "被验收提交")} id="task-pr-verified">
          <.tooltip
            :if={@stale_verified?}
            id="task-pr-verified-tip"
            text={dgettext("ui", "验收后分支上有新提交")}
          >
            <code class="font-mono text-label text-warning-fg" data-stale title={@pr.verified_sha}>
              {short_sha(@pr.verified_sha)}
            </code>
          </.tooltip>
          <code
            :if={!@stale_verified?}
            class="font-mono text-label text-fg-muted"
            title={@pr.verified_sha}
          >
            {short_sha(@pr.verified_sha)}
          </code>
        </.property_row>
        <.property_row
          :if={@pr.state == "merged" and @pr.merged_sha != nil}
          label={dgettext("ui", "合并提交")}
          id="task-pr-merged"
        >
          <code class="font-mono text-label text-fg-muted" title={@pr.merged_sha}>
            {short_sha(@pr.merged_sha)}
          </code>
          <.relative_time
            :if={@pr.merged_at}
            id="task-pr-merged-at"
            at={@pr.merged_at}
            now={@now}
            class="text-caption text-fg-subtle"
          />
        </.property_row>
        <.property_row
          :if={@pr.auto_reopen_count > 0}
          label={dgettext("ui", "自动重开")}
          id="task-pr-reopens"
        >
          <.tooltip
            id="task-pr-reopens-tip"
            text={dgettext("ui", "CI 失败或冲突时自动重开让 Agent 修复，最多 %{n} 次", n: @pr.max_auto_reopens)}
          >
            <span>{@pr.auto_reopen_count} / {@pr.max_auto_reopens}</span>
          </.tooltip>
        </.property_row>
      </.property_list>
      <p :if={@pr.merge_request} id="task-pr-merge-request" class="text-caption text-fg-muted">
        {dgettext("ui", "%{actor} 请求了立即合并", actor: request_actor(@pr.merge_request))}
        <span :if={@request_at}>
          · <.relative_time id="task-pr-merge-request-at" at={@request_at} now={@now} />
        </span>
        <span :if={@pr.merge_request.skip_independence?} data-skip>
          {dgettext("ui", "（跳过独立性检查）")}
        </span>
      </p>
      <div
        :if={@reverify or @pr.can.merge_now or @retry?}
        id="task-pr-actions"
        class="flex flex-wrap items-center gap-2"
      >
        <.button
          :if={@reverify}
          id="task-pr-reverify"
          size="sm"
          variant="primary"
          disabled={@busy != nil}
          phx-click="pr_ask_reverify"
        >
          {if(@busy == :reverify,
            do: dgettext("ui", "重新验收中…"),
            else: dgettext("ui", "按当前提交重新验收")
          )}
        </.button>
        <.button
          :if={@pr.can.merge_now}
          id="task-pr-merge-now"
          size="sm"
          disabled={@busy != nil}
          phx-click="pr_ask_merge"
        >
          {dgettext("ui", "立即合并")}
        </.button>
        <.button
          :if={@retry?}
          id="task-pr-retry"
          size="sm"
          variant="ghost"
          disabled={@busy != nil}
          phx-click="pr_retry"
          phx-disable-with={dgettext("ui", "重试中…")}
        >
          {if(@retried, do: dgettext("ui", "已重试"), else: dgettext("ui", "重试"))}
        </.button>
      </div>
    </div>
    """
  end

  defp request_actor(%{by: %{name: name}}), do: name
  defp request_actor(_request), do: dgettext("ui", "已删除的身份")

  defp parse_time(nil), do: nil
  defp parse_time(%DateTime{} = at), do: at

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  ## Merge preview of the 验收 panel (D11)

  @doc """
  What verifying would lead to (R3 `verify_preview/2`): the commit to be recorded, the
  CI state and the outcome. Nothing when `preview` is nil (no GitHub repository).
  """
  attr :preview, :map, default: nil

  def merge_preview(%{preview: nil} = assigns), do: ~H""

  def merge_preview(assigns) do
    {tone, label} = checks_badge(assigns.preview.checks_state)
    assigns = assign(assigns, checks_tone: tone, checks_label: label)

    ~H"""
    <div
      id="verify-merge-preview"
      class="mb-4 flex flex-col gap-1 rounded-field border border-border tint-info px-3 py-2 text-body text-info-fg"
    >
      <p data-commit>
        <span class="text-fg-muted">{dgettext("ui", "将记下的提交")}</span>
        <code :if={@preview.verified_sha} class="font-mono text-label" title={@preview.verified_sha}>
          {short_sha(@preview.verified_sha)}
        </code>
        <span :if={!@preview.verified_sha}>
          {dgettext("ui", "还没有运行推送的提交，验收不会记下提交，也不会自动合并")}
        </span>
      </p>
      <p class="flex items-center gap-1.5">
        <span class="text-fg-muted">CI</span>
        <.badge tone={@checks_tone} data-checks={@preview.checks_state}>{@checks_label}</.badge>
      </p>
      <p :if={@preview.outcome != "no_commit"} data-outcome={@preview.outcome}>
        <span class="text-fg-muted">{dgettext("ui", "验收后")}</span>
        {outcome_text(@preview)}
      </p>
    </div>
    """
  end

  @doc "The 验收后 line of the merge preview (D11)."
  def outcome_text(%{outcome: "auto_merge", base_branch: base}),
    do: dgettext("ui", "CI 通过后自动合并到 %{branch}", branch: base)

  def outcome_text(%{outcome: "not_independent"}),
    do: dgettext("ui", "你不独立于这份代码的出处（或你是执行方），不会自动合并")

  def outcome_text(%{outcome: "policy_manual"}),
    do: dgettext("ui", "项目设置为不自动合并，需要在 GitHub 上合并或点立即合并")

  def outcome_text(%{outcome: "agent_verified"}), do: dgettext("ui", "项目要求人验收后才自动合并")

  def outcome_text(%{outcome: "repository_unavailable"}), do: dgettext("ui", "仓库不可用，不会合并")
  def outcome_text(_preview), do: dgettext("ui", "合并时再检查")
end

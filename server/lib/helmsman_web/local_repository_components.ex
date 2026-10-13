defmodule HelmsmanWeb.LocalRepositoryComponents do
  @moduledoc """
  Local repository visuals (add-local-repositories-ui D2, D3, D6, D7): the status badge
  and its explanation, the project chip, the task's local branch card and its review
  commands.

  A repository is the view of `Helmsman.LocalRepositories.list/1`: `%{id, name,
  daemon_name, owner, status, unavailable_reason, default_branch, removed, path}`
  (`path` nil for readers who may not see it).
  """
  use HelmsmanWeb, :html

  @doc """
  The status of a repository view: `:online`, `:offline`, `:unavailable`, `:removed`
  (wins over the status) or `:unknown`.
  """
  def status(%{removed: true}), do: :removed
  def status(%{status: "online"}), do: :online
  def status(%{status: "offline"}), do: :offline
  def status(%{status: "unavailable"}), do: :unavailable
  def status(_repository), do: :unknown

  @doc "Badge tone and label of a status (D3)."
  def status_spec(:online), do: {:success, dgettext("ui", "可用")}
  def status_spec(:offline), do: {:muted, dgettext("ui", "机器离线")}
  def status_spec(:unavailable), do: {:warning, dgettext("ui", "不可用")}
  def status_spec(:removed), do: {:danger, dgettext("ui", "已移除")}
  def status_spec(:unknown), do: {:muted, dgettext("ui", "未知")}

  @doc """
  The reason of an unavailable repository: `{:translated, text}` for the server's
  fixed reasons, `{:reported, text}` (the daemon's own English text, shown as is) for
  any other, nil without a reason.
  """
  def reason_text(nil), do: nil
  def reason_text("not configured on the machine"), do: {:translated, dgettext("ui", "机器上已不再配置")}

  def reason_text("not shared with this workspace on the machine"),
    do: {:translated, dgettext("ui", "机器上已不再对本工作区开放")}

  def reason_text("duplicate name on the machine"),
    do: {:translated, dgettext("ui", "机器上有重名的登记")}

  def reason_text(reason) when is_binary(reason), do: {:reported, reason}

  @doc """
  The plain-text explanation of a non-available repository (D3), nil when available.
  """
  def status_note(repository) do
    case status(repository) do
      :online -> nil
      :offline -> dgettext("ui", "所在机器离线，运行会等它上线后执行")
      :removed -> dgettext("ui", "该本地仓库已从工作区移除，绑定它的项目无法执行运行")
      _ -> reason_plain(repository.unavailable_reason)
    end
  end

  defp reason_plain(reason) do
    case reason_text(reason) do
      {:translated, text} -> text
      {:reported, text} -> dgettext("ui", "机器报告：%{reason}", reason: text)
      nil -> dgettext("ui", "原因未知")
    end
  end

  @doc """
  Status badge of a repository (D3) with `data-status`. With `reason`, an unavailable
  repository's reason follows the badge inline; otherwise the explanation of a
  non-available status is the badge's tooltip.
  """
  attr :id, :string, required: true
  attr :repository, :map, required: true
  attr :reason, :boolean, default: false
  attr :class, :any, default: nil

  def status_badge(assigns) do
    status = status(assigns.repository)
    {tone, label} = status_spec(status)

    assigns =
      assign(assigns,
        status: status,
        tone: tone,
        label: label,
        note: status_note(assigns.repository),
        inline?: assigns.reason and status == :unavailable
      )

    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={["inline-flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5", @class]}
    >
      <.tooltip :if={@note && !@inline?} id={"#{@id}-note"} text={@note}>
        <.badge tone={@tone} tabindex="0">{@label}</.badge>
      </.tooltip>
      <.badge :if={!@note || @inline?} tone={@tone}>{@label}</.badge>
      <.unavailable_reason
        :if={@inline?}
        id={"#{@id}-reason"}
        reason={@repository.unavailable_reason}
      />
    </span>
    """
  end

  @doc """
  The reason of an unavailable repository: translated, or the daemon's English text as
  is (`lang="en"`) after 「机器报告：」.
  """
  attr :id, :string, default: nil
  attr :reason, :string, default: nil
  attr :class, :any, default: nil

  def unavailable_reason(assigns) do
    assigns = assign(assigns, :text, reason_text(assigns.reason))

    ~H"""
    <span id={@id} class={["text-caption text-fg-muted", @class]} data-reason>
      <%= case @text do %>
        <% {:translated, text} -> %>
          {text}
        <% {:reported, text} -> %>
          {dgettext("ui", "机器报告：")}<span lang="en">{text}</span>
        <% nil -> %>
          {dgettext("ui", "原因未知")}
      <% end %>
    </span>
    """
  end

  @doc """
  The bound local repository of a project (D6): `hard-drive` icon, name, 「· <machine>」
  and an optional `→ <branch>`; a warning mark with the D3 explanation when it is not
  available. Not a link.
  """
  attr :id, :string, required: true
  attr :repository, :map, required: true
  attr :branch, :string, default: nil
  attr :class, :any, default: nil

  def local_repo_chip(assigns) do
    assigns =
      assign(assigns,
        status: status(assigns.repository),
        note: status_note(assigns.repository)
      )

    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={["inline-flex min-w-0 items-center gap-1 text-caption text-fg-muted", @class]}
    >
      <.icon name="lucide-hard-drive" class="size-3.5 flex-none" />
      <span class="truncate font-mono" data-local-repository>{@repository.name}</span>
      <span class="flex-none" data-machine>· {@repository.daemon_name}</span>
      <span :if={@branch} class="flex-none" data-branch>
        → <span class="font-mono">{@branch}</span>
      </span>
      <.tooltip :if={@note} id={"#{@id}-note"} text={@note} class="flex-none">
        <.icon
          name="lucide-triangle-alert"
          class="size-3.5 text-warning"
          label={@note}
          data-unavailable
        />
      </.tooltip>
    </span>
    """
  end

  ## Local branch card (D7)

  @doc """
  The task's 本地分支 card: `branch` is the view of
  `Helmsman.LocalRepositories.get_branch/2` (nil before the first delivery), `project`
  the task's project as read by `Helmsman.Projects`. With `can_act?` (`:transition_task`)
  it has 检查合并状态 (disabled during the `cooldown?` and while the repository is not
  available), 标记为已合并 and, on a merge marked by a person, 撤销标记.
  """
  attr :branch, :map, default: nil
  attr :project, :map, default: nil
  attr :can_act?, :boolean, default: false
  attr :cooldown?, :boolean, default: false

  def local_branch_card(assigns) do
    assigns = assign(assigns, card_assigns(assigns.branch, assigns.project))

    ~H"""
    <section
      id="task-local-branch"
      aria-labelledby="task-local-branch-title"
      class="flex flex-col gap-2"
      data-state={@branch && @branch.state}
    >
      <div class="flex items-center justify-between gap-2">
        <h2 id="task-local-branch-title" class="text-label font-medium text-fg-muted">
          {dgettext("ui", "本地分支")}
        </h2>
        <span :if={@branch} id="task-local-branch-state">
          <.badge :if={@merged?} tone={:success}>
            <.icon name="lucide-git-merge" class="size-3.5" />{dgettext("ui", "已合并")}
          </.badge>
          <.badge :if={!@merged?} tone={:muted}>{dgettext("ui", "未合并")}</.badge>
        </span>
      </div>

      <.property_list :if={@repository}>
        <.property_row label={dgettext("ui", "仓库")} id="task-local-branch-repository">
          <span class="flex min-w-0 flex-col gap-0.5">
            <span class="flex min-w-0 flex-wrap items-center gap-1">
              <.local_repo_chip id="task-local-branch-chip" repository={@repository} />
              <span class="text-caption text-fg-muted" data-owner>（{@repository.owner.name}）</span>
            </span>
            <span :if={@rebound?} id="task-local-branch-rebound" class="text-caption text-fg-subtle">
              {dgettext("ui", "项目已改绑：这是交付到原仓库的分支")}
            </span>
          </span>
        </.property_row>
        <.property_row :if={@branch} label={dgettext("ui", "任务分支")}>
          <span class="flex min-w-0 items-center gap-1">
            <code id="task-local-branch-name" class="truncate font-mono text-label text-fg">
              {@branch.branch}
            </code>
            <.copy_button
              id="task-local-branch-copy-branch"
              text={@branch.branch}
              label={dgettext("ui", "复制分支名")}
              target="#task-local-branch-name"
            />
          </span>
        </.property_row>
        <.property_row :if={@branch} label={dgettext("ui", "最近交付")}>
          <span class="flex min-w-0 flex-wrap items-center gap-x-1">
            <code
              id="task-local-branch-head"
              class="font-mono text-label text-fg"
              title={@branch.head_sha}
            >
              {String.slice(@branch.head_sha, 0, 7)}
            </code>
            <.copy_button
              id="task-local-branch-copy-head"
              text={@branch.head_sha}
              label={dgettext("ui", "复制完整 SHA")}
            />
            <.relative_time
              :if={@branch.updated_at}
              id={"task-local-branch-updated-#{:erlang.phash2(@branch.updated_at)}"}
              at={@branch.updated_at}
              class="text-caption text-fg-muted"
            />
          </span>
        </.property_row>
        <.property_row :if={@branch} label={dgettext("ui", "基础分支")}>
          <code id="task-local-branch-base" class="font-mono text-label text-fg">
            {@branch.base_branch || "—"}
          </code>
        </.property_row>
      </.property_list>

      <div
        :if={@merged?}
        id="task-local-branch-merged"
        class="flex flex-col gap-1 text-body text-fg-muted"
      >
        <p :if={@branch.merged_by == nil} data-detected>
          {dgettext("ui", "已检测到合并进 %{base}", base: @branch.base_branch || "—")}
          <.relative_time
            :if={@branch.merged_at}
            id={"task-local-branch-merged-at-#{:erlang.phash2(@branch.merged_at)}"}
            at={@branch.merged_at}
          />
        </p>
        <p :if={@branch.merged_by} data-marked>
          {dgettext("ui", "%{name} 标记为已合并", name: @branch.merged_by.name)}
          <.relative_time
            :if={@branch.merged_at}
            id={"task-local-branch-merged-at-#{:erlang.phash2(@branch.merged_at)}"}
            at={@branch.merged_at}
          />
        </p>
        <p
          :if={@branch.merged_by && @branch.merge_note}
          id="task-local-branch-note"
          class="whitespace-pre-line text-fg"
        >
          {@branch.merge_note}
        </p>
      </div>

      <p :if={!@branch && @repository} id="task-local-branch-pending" class="text-body text-fg-muted">
        {dgettext("ui", "还没有交付。运行成功收尾后，任务分支会出现在 %{machine} 上的仓库 %{name} 里。",
          machine: @repository.daemon_name,
          name: @repository.name
        )}
      </p>

      <details :if={@commands} id="task-local-branch-commands" class="group">
        <summary class="cursor-pointer text-body text-fg hover:text-brand-fg">
          {dgettext("ui", "在本地审查与合并")}
        </summary>
        <div class="mt-2 flex flex-col gap-2">
          <p :if={!@repository.path} id="task-local-branch-where" class="text-caption text-fg-muted">
            {dgettext("ui", "在 %{machine} 上仓库 %{name} 的目录中执行",
              machine: @repository.daemon_name,
              name: @repository.name
            )}
          </p>
          <div :for={c <- @commands} class="flex flex-col gap-1">
            <span class="text-caption text-fg-muted">{c.label}</span>
            <.copy_command id={"task-local-branch-cmd-#{c.id}"} text={c.command} />
          </div>
          <p
            :if={Enum.any?(@commands, &(&1.id == :merge))}
            id="task-local-branch-merge-note"
            class="flex items-start gap-1 rounded-field border border-border tint-warning px-2 py-1.5 text-caption text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="mt-0.5 size-3.5 flex-none" />
            <span>
              {dgettext(
                "ui",
                "会把该仓库当前检出的分支切换为 %{base} 再合并。工作区有冲突的改动、%{base} 已在另一个 worktree 中检出、或这是 bare 仓库时，switch 会失败（不会合错分支）；这些情况请在检出了 %{base} 的那个工作副本里执行 git merge --no-ff %{branch}。",
                base: @branch.base_branch,
                branch: @branch.branch
              )}
            </span>
          </p>
        </div>
      </details>
      <p
        :if={@branch && !@commands}
        id="task-local-branch-no-base"
        class="text-caption text-fg-muted"
      >
        {dgettext(
          "ui",
          "项目没有设置基础分支、仓库也没有上报默认分支；在项目的『仓库与合并』中设置基础分支后显示审查命令"
        )}
      </p>

      <p
        :if={@note}
        id="task-local-branch-status"
        class="flex items-start gap-1 text-caption text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-3.5 flex-none" />{@note}
      </p>

      <div
        :if={@can_act? and @branch != nil}
        id="task-local-branch-actions"
        class="flex flex-wrap gap-2"
      >
        <.button
          :if={!@merged?}
          id="task-local-branch-refresh"
          size="sm"
          icon="lucide-refresh-cw"
          disabled={@cooldown?}
          disabled_reason={if(!@online?, do: dgettext("ui", "机器离线或仓库不可用，恢复后会自动检查"))}
          phx-click="local_branch_refresh"
        >
          {dgettext("ui", "检查合并状态")}
        </.button>
        <.button
          :if={!@merged?}
          id="task-local-branch-mark"
          size="sm"
          icon="lucide-git-merge"
          phx-click="local_branch_open_mark"
        >
          {dgettext("ui", "标记为已合并")}
        </.button>
        <.button
          :if={@merged? and @branch.merged_by != nil}
          id="task-local-branch-unmark"
          size="sm"
          variant="ghost"
          phx-click="local_branch_ask_unmark"
        >
          {dgettext("ui", "撤销标记")}
        </.button>
      </div>
    </section>
    """
  end

  defp card_assigns(branch, project) do
    bound = project && project.local_repository
    repository = (branch && branch.local_repository) || bound

    %{
      repository: repository,
      rebound?: rebound?(branch, repository, bound),
      merged?: match?(%{state: "merged"}, branch),
      commands: branch && review_commands(branch, repository && repository.path),
      note: repository && status_note(repository),
      online?: repository != nil and status(repository) == :online
    }
  end

  defp rebound?(nil, _repository, _bound), do: false
  defp rebound?(_branch, nil, _bound), do: false
  defp rebound?(_branch, repository, bound), do: bound == nil or bound.id != repository.id

  ## Assigning to another machine (D10)

  @doc """
  The warning when the managed agent's runtime is on another machine than the project's
  local repository (D10), else nil. `entry` is the agent's `Dispatch.availability/1`
  entry.
  """
  def other_machine(local_repository, agent, entry)

  def other_machine(%{daemon_id: id} = local, agent, %{runtime: %{daemon_id: other} = runtime})
      when id != other do
    dgettext(
      "ui",
      "这个项目的仓库 %{name} 在 %{machine} 上，%{agent} 的运行时在 %{other} 上：运行会以『准备工作区』失败。请改派给 %{machine} 上的 Agent。",
      name: local.name,
      machine: local.daemon_name,
      agent: agent,
      other: runtime.daemon_name
    )
  end

  def other_machine(_local, _agent, _entry), do: nil

  ## Review commands (D7)

  @doc """
  The local review commands of a task branch (D7, #44 decision 10): `[%{id, label,
  command}]` with `:log` and `:diff`, and `:merge` while the branch is not merged
  (`switch <base> && merge --no-ff <branch>`). With `path` every command runs with
  `git -C <path>`; without it in the repository's directory. Names are quoted for a
  POSIX shell when needed. nil when the base branch is unknown.
  """
  def review_commands(%{base_branch: nil}, _path), do: nil

  def review_commands(%{branch: branch, base_branch: base, state: state}, path) do
    git = if path, do: "git -C #{shell_quote(path)}", else: "git"
    b = shell_quote(branch)
    base = shell_quote(base)

    commands = [
      %{id: :log, label: dgettext("ui", "查看提交"), command: "#{git} log --oneline #{base}..#{b}"},
      %{id: :diff, label: dgettext("ui", "查看差异"), command: "#{git} diff #{base}...#{b}"}
    ]

    if state == "merged" do
      commands
    else
      commands ++
        [
          %{
            id: :merge,
            label: dgettext("ui", "合并进基础分支"),
            command: "#{git} switch #{base} && #{git} merge --no-ff #{b}"
          }
        ]
    end
  end

  @doc "Quotes `value` for a POSIX shell unless it only has safe characters."
  def shell_quote(value) when is_binary(value) do
    if value != "" and Regex.match?(~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/, value),
      do: value,
      else: "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end

defmodule HelmsmanWeb.TaskLocalBranch do
  @moduledoc """
  The task page's local branch (add-local-repositories-ui D7, D8): the task's branch in
  its project's local repository, the 检查合并状态 cooldown, the 标记为已合并 panel and
  the 撤销标记 dialog. `HelmsmanWeb.TaskLive.Show` keeps the state in the
  `:local_branch` assign and forwards the `local_branch_*` events and the
  `:local_branch_cooldown_over` message.

  The mark panel holds `confirmed_sha`, the commit the user last confirmed explicitly
  (the branch head when the panel opened, then only what an 改为确认 click carried), and
  `latest_sha`, the head last read. The mark is submitted with `expected_head_sha:
  confirmed_sha`, so a delivery the user did not see is never marked merged (D8.1).
  """
  use HelmsmanWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Helmsman.{LocalRepositories, Policy, Projects}
  alias HelmsmanWeb.LocalRepositoryComponents

  @cooldown_ms 30_000
  @max_note 2000

  ## State

  @doc "Reads the project and the task's branch into the `:local_branch` assign."
  def load(socket, task) do
    scope = socket.assigns.current_scope

    state = %{
      ident: task.id,
      project_key: task.project_key,
      project: nil,
      branch: nil,
      can_act?: Policy.authorize(scope, :transition_task) == :ok,
      cooldown?: false,
      panel: nil,
      unmark?: false
    }

    socket |> assign(:local_branch, state) |> reload_project()
  end

  @doc "Re-reads the branch (`{:local_branch_changed, ident}`) and checks the open overlays."
  def reload(socket) do
    state = socket.assigns.local_branch
    branch = read_branch(socket.assigns.current_scope, state.ident)
    assign(socket, :local_branch, follow(%{state | branch: branch}))
  end

  @doc "Re-reads the project (its binding, the repository's status) and the branch."
  def reload_project(socket) do
    state = socket.assigns.local_branch

    project =
      case Projects.get(socket.assigns.current_scope, state.project_key) do
        {:ok, project} -> project
        {:error, _} -> nil
      end

    socket |> assign(:local_branch, %{state | project: project}) |> reload()
  end

  defp read_branch(scope, ident) do
    case LocalRepositories.get_branch(scope, ident) do
      {:ok, branch} -> branch
      {:error, _} -> nil
    end
  end

  # The panel learns the latest head (only a hint); the dialog closes when the branch is
  # no longer merged by a person.
  defp follow(%{panel: panel, branch: branch} = state) do
    panel = if panel && branch, do: %{panel | latest_sha: branch.head_sha}, else: panel
    unmark? = state.unmark? and match?(%{state: "merged", merged_by: %{}}, branch)
    %{state | panel: panel, unmark?: unmark?}
  end

  @doc "Whether the task page shows the card: a local project, or a delivered branch."
  def shown?(%{project: %{local_repository: %{}}}), do: true
  def shown?(%{branch: %{}}), do: true
  def shown?(_state), do: false

  @doc """
  The branch when it is on the project's current local repository, else nil: what
  验收 records (`Helmsman.Tasks.VerifiedSha`). A branch delivered to the repository
  bound before stays on the card (D7) but is not this.
  """
  def current_branch(%{
        branch: %{local_repository: %{id: id}} = branch,
        project: %{local_repository_id: id}
      }),
      do: branch

  def current_branch(_state), do: nil

  @doc "Whether the task's project is bound to a local repository."
  def local?(%{project: %{local_repository: %{}}}), do: true
  def local?(_state), do: false

  ## Events

  @doc "Handles a `local_branch_*` event (without the prefix)."
  def handle_event("refresh", _params, socket) do
    state = socket.assigns.local_branch

    with true <- state.can_act? and not state.cooldown?,
         %{state: "open"} = branch <- state.branch do
      case LocalRepositories.refresh(socket.assigns.current_scope, state.ident) do
        :ok ->
          Process.send_after(self(), :local_branch_cooldown_over, @cooldown_ms)
          machine = branch.local_repository && branch.local_repository.daemon_name

          socket
          |> assign(:local_branch, %{state | cooldown?: true})
          |> put_flash(:info, dgettext("ui", "已请求 %{machine} 重新检查，结果稍后自动出现", machine: machine))

        {:error, :not_found} ->
          reload(socket)

        {:error, _} ->
          put_flash(socket, :error, dgettext("ui", "没有权限执行此操作"))
      end
    else
      _ -> socket
    end
  end

  def handle_event("open_mark", _params, socket) do
    case socket.assigns.local_branch do
      %{can_act?: true, branch: %{state: "open", head_sha: sha}} = state ->
        panel = %{confirmed_sha: sha, latest_sha: sha, note: "", error: nil}
        assign(socket, :local_branch, %{state | panel: panel})

      _ ->
        socket
    end
  end

  def handle_event("close_mark", _params, socket), do: put_panel(socket, nil)

  def handle_event("mark_change", %{"local_merge" => %{"note" => note}}, socket),
    do: update_panel(socket, &%{&1 | note: note})

  # D8.1: the confirmed commit is the one the clicked button was rendered for.
  def handle_event("confirm_latest", %{"sha" => sha}, socket) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: update_panel(socket, &%{&1 | confirmed_sha: sha}),
      else: socket
  end

  def handle_event("mark", %{"local_merge" => %{"note" => note}}, socket) do
    case socket.assigns.local_branch do
      %{panel: %{} = panel} = state ->
        panel = %{panel | note: note, error: nil}
        socket = assign(socket, :local_branch, %{state | panel: panel})

        if String.length(note) > @max_note do
          update_panel(socket, &%{&1 | error: note_too_long()})
        else
          scope = socket.assigns.current_scope
          opts = [expected_head_sha: panel.confirmed_sha]
          marked(socket, LocalRepositories.mark_merged(scope, state.ident, note, opts))
        end

      _ ->
        socket
    end
  end

  def handle_event("ask_unmark", _params, socket) do
    case socket.assigns.local_branch do
      %{can_act?: true, branch: %{state: "merged", merged_by: %{}}} = state ->
        assign(socket, :local_branch, %{state | unmark?: true})

      _ ->
        socket
    end
  end

  def handle_event("dismiss_unmark", _params, socket),
    do: assign(socket, :local_branch, %{socket.assigns.local_branch | unmark?: false})

  # Only while the confirmation is still valid: a click in flight after the dialog closed
  # (the mark was undone, maybe detected merged since) must not clear a detected merge.
  def handle_event("unmark", _params, socket) do
    case socket.assigns.local_branch do
      %{can_act?: true, unmark?: true, branch: %{state: "merged", merged_by: %{}}} = state ->
        socket
        |> assign(:local_branch, %{state | unmark?: false})
        |> unmark(state.ident)

      state ->
        socket |> assign(:local_branch, %{state | unmark?: false}) |> reload()
    end
  end

  def handle_event(_event, _params, socket), do: socket

  defp unmark(socket, ident) do
    # manual_only: the branch lock re-checks the mark (code-review-1 P2-2).
    case LocalRepositories.mark_unmerged(socket.assigns.current_scope, ident, manual_only: true) do
      {:ok, _} ->
        socket |> put_flash(:info, dgettext("ui", "已撤销已合并标记")) |> reload()

      {:error, {:invalid_state, _}} ->
        socket |> put_flash(:error, dgettext("ui", "已不是已合并")) |> reload()

      {:error, :not_manual} ->
        socket |> put_flash(:error, dgettext("ui", "已由自动检测确认合并，不能撤销")) |> reload()

      {:error, reason} ->
        socket |> put_flash(:error, failure(reason)) |> reload()
    end
  end

  @doc "The 检查合并状态 cooldown is over."
  def cooldown_over(socket),
    do: assign(socket, :local_branch, %{socket.assigns.local_branch | cooldown?: false})

  defp marked(socket, {:ok, _view}) do
    socket |> put_panel(nil) |> put_flash(:info, dgettext("ui", "已标记为已合并")) |> reload()
  end

  defp marked(socket, {:error, {:head_changed, sha}}),
    do: update_panel(socket, &%{&1 | latest_sha: sha})

  defp marked(socket, {:error, :note_too_long}),
    do: update_panel(socket, &%{&1 | error: note_too_long()})

  defp marked(socket, {:error, {:invalid_state, _}}) do
    socket |> put_panel(nil) |> put_flash(:error, dgettext("ui", "已经是已合并")) |> reload()
  end

  defp marked(socket, {:error, reason}),
    do: socket |> put_panel(nil) |> put_flash(:error, failure(reason)) |> reload()

  defp failure(:not_found), do: dgettext("ui", "这个任务还没有交付的分支")
  defp failure(:forbidden), do: dgettext("ui", "没有权限标记这个任务")
  defp failure(_reason), do: dgettext("ui", "操作失败，请稍后重试")

  defp note_too_long, do: dgettext("ui", "说明最多 2000 字")

  defp put_panel(socket, panel),
    do: assign(socket, :local_branch, %{socket.assigns.local_branch | panel: panel})

  defp update_panel(socket, fun) do
    case socket.assigns.local_branch do
      %{panel: %{} = panel} = state ->
        assign(socket, :local_branch, %{state | panel: fun.(panel)})

      _ ->
        socket
    end
  end

  ## Rendering

  @doc "The 本地分支 card (D7) when `shown?/1`."
  attr :state, :map, required: true

  def card(assigns) do
    ~H"""
    <LocalRepositoryComponents.local_branch_card
      :if={shown?(@state)}
      branch={@state.branch}
      project={@state.project}
      can_act?={@state.can_act?}
      cooldown?={@state.cooldown?}
    />
    """
  end

  @doc "The 标记为已合并 panel (D8.1); always rendered so that closing restores focus."
  attr :state, :map, required: true

  def mark_panel(%{state: %{panel: nil}} = assigns) do
    ~H"""
    <.side_panel
      id="local-merge-panel"
      show={false}
      title=""
      on_cancel={JS.push("local_branch_close_mark")}
    >
      <div />
    </.side_panel>
    """
  end

  def mark_panel(assigns) do
    panel = assigns.state.panel

    assigns =
      assign(assigns,
        panel: panel,
        changed?: panel.latest_sha != nil and panel.latest_sha != panel.confirmed_sha
      )

    ~H"""
    <.side_panel
      id="local-merge-panel"
      show
      title={dgettext("ui", "标记为已合并 · %{ident}", ident: @state.ident)}
      dirty={@panel.note != ""}
      on_cancel={JS.push("local_branch_close_mark")}
    >
      <div
        :if={@changed?}
        id="local-merge-head-changed"
        role="alert"
        class="mb-4 flex flex-col items-start gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <span>
          {dgettext("ui", "有新的交付 %{latest}，你确认的是 %{confirmed}；提交会被拒绝",
            latest: short(@panel.latest_sha),
            confirmed: short(@panel.confirmed_sha)
          )}
        </span>
        <.button
          id="local-merge-confirm-latest"
          size="sm"
          phx-click="local_branch_confirm_latest"
          phx-value-sha={@panel.latest_sha}
        >
          {dgettext("ui", "改为确认 %{sha}", sha: short(@panel.latest_sha))}
        </.button>
      </div>
      <p id="local-merge-description" class="mb-4 text-body text-fg-muted">
        {dgettext("ui", "用于压缩合并、变基合并、cherry-pick 等检测不到的合并。将记为提交")}
        <code class="font-mono text-fg" data-confirmed-sha>{short(@panel.confirmed_sha)}</code>
        {dgettext("ui", "已合并")}
      </p>
      <.form
        for={%{}}
        as={:local_merge}
        id="local-merge-form"
        phx-change="local_branch_mark_change"
        phx-submit="local_branch_mark"
      >
        <.input
          type="textarea"
          id="local-merge-note"
          name="local_merge[note]"
          label={dgettext("ui", "说明（可选）")}
          value={@panel.note}
          maxlength="2000"
          rows="4"
          errors={List.wrap(@panel.error)}
          phx-debounce="300"
        />
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button id="local-merge-submit" type="submit" form="local-merge-form" variant="primary">
            {dgettext("ui", "标记为已合并")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  @doc "The 撤销标记 confirmation (D8.2)."
  attr :state, :map, required: true

  def unmark_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="local-unmerge-confirm"
      show={@state.unmark?}
      title={dgettext("ui", "撤销已合并标记？")}
      danger
      confirm_label={dgettext("ui", "撤销标记")}
      on_confirm="local_branch_unmark"
      on_cancel={JS.push("local_branch_dismiss_unmark")}
    >
      {dgettext("ui", "任务分支 %{branch} 会回到未合并；依赖这个任务的任务将重新等待它合并。",
        branch: (@state.branch && @state.branch.branch) || ""
      )}
    </.confirm_dialog>
    """
  end

  @doc """
  The 验收 panel's preview in the local mode (D9), nil for other projects: the commit
  that will be recorded and what happens after.
  """
  attr :state, :map, required: true

  def verify_preview(assigns) do
    assigns = assign(assigns, :branch, current_branch(assigns.state))

    ~H"""
    <div
      :if={local?(@state)}
      id="verify-local-preview"
      class="mb-4 flex flex-col gap-1 rounded-field border border-border tint-info px-3 py-2 text-body text-info-fg"
    >
      <p :if={@branch} data-commit>
        {dgettext("ui", "将记下的提交：")}<code class="font-mono">{short(@branch.head_sha)}</code>
      </p>
      <p :if={!@branch && !@state.branch} data-commit>
        {dgettext("ui", "还没有交付的分支，验收不会记下提交")}
      </p>
      <p :if={!@branch && @state.branch} data-commit>
        {dgettext("ui", "还没有交付到当前绑定仓库的分支，验收不会记下提交")}
      </p>
      <p :if={match?(%{state: "merged"}, @branch)} data-after>
        {dgettext("ui", "验收后：分支已合并进 %{base}", base: @branch.base_branch || "—")}
      </p>
      <p :if={!match?(%{state: "merged"}, @branch)} data-after>
        {dgettext(
          "ui",
          "验收后：Helmsman 不会合并或删除分支。在本地合并后会自动检测；检测不到时在『本地分支』卡片上标记为已合并"
        )}
      </p>
    </div>
    """
  end

  defp short(nil), do: ""
  defp short(sha), do: String.slice(sha, 0, 7)
end

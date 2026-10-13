defmodule HelmsmanWeb.TaskPullRequest do
  @moduledoc """
  The 拉取请求 card of the task page and its operations (add-github-ui D8, D10, D13).

  The page keeps the state in `socket.assigns.task_pr`:

    * `repository` — the project's bound repository (`%{full_name, available}`) or nil;
    * `pr` — the view of `Helmsman.GitHub.PullRequests.get/2` (replaced on every read);
    * `pending_op` — the confirmation dialog or panel that is open
      (`%{kind: :reverify | :merge_now | :skip, pr_key, head_sha, ...}`), cleared when
      it closes or when the pull request it is about is no longer the current one;
    * `operation` — the operation in progress (`%{id, kind, pr_key, head_sha}`); it
      disables the card's actions and survives changes of the pull request, so its
      result is always handled (only a result with the current `id` is).

  Re-verifying reads GitHub, so it runs in `start_async(:pr_reverify, …)`; merging now
  and retrying only write and enqueue, and run in the event handler.

  The host forwards `pr_*` events to `handle_event/4`, `:pr_reverify` results to
  `handle_async/4`, `:pr_retried` to `handle_info/2`, calls `reload/1` /
  `reload_project/1` on notifications and renders `card/1` and `dialogs/1`.
  """
  use HelmsmanWeb, :html

  require Logger
  require Phoenix.LiveView

  import HelmsmanWeb.GitHubComponents, only: [pr_key: 1, pr_ref: 1, short_sha: 1]

  alias Helmsman.GitHub.PullRequests
  alias Helmsman.Projects
  alias HelmsmanWeb.GitHubComponents
  alias HelmsmanWeb.TaskLive.TransitionErrors

  @max_reason_bytes 1000
  @retried_ms 2000

  @doc "Initial state and the first read of the project's repository and the PR."
  def init(socket) do
    socket
    |> Phoenix.Component.assign(:task_pr, %{
      repository: nil,
      pr: nil,
      pending_op: nil,
      operation: nil,
      next_id: 1,
      retried?: false,
      unknown: nil
    })
    |> reload_project()
  end

  @doc "Reads the project's repository again, then the pull request (D13)."
  def reload_project(socket) do
    %{current_scope: scope, task: task} = socket.assigns

    repository =
      case Projects.get(scope, task.project_key) do
        {:ok, project} -> project.repository
        {:error, _} -> nil
      end

    socket |> update_state(&%{&1 | repository: repository}) |> reload()
  end

  @doc """
  Reads the current pull request again (replacing the old view) and closes a dialog
  or panel about a pull request that is no longer the current one (D10).
  """
  def reload(socket) do
    %{current_scope: scope, task: task} = socket.assigns

    pr =
      case PullRequests.get(scope, task.id) do
        {:ok, pr} -> pr
        {:error, _} -> nil
      end

    socket
    |> update_state(&%{&1 | pr: pr})
    |> log_unknown()
    |> check_pending()
  end

  # An unknown reason code is logged once per code (D9).
  defp log_unknown(socket) do
    state = socket.assigns.task_pr
    verdict = state.pr && GitHubComponents.verdict(state.pr, socket.assigns.task.status)
    unknown = verdict && verdict.unknown

    if unknown != nil and unknown != state.unknown do
      Logger.warning(
        "Unknown pull request reason #{inspect(unknown)} for #{socket.assigns.task.id}"
      )
    end

    update_state(socket, &%{&1 | unknown: unknown})
  end

  defp check_pending(socket) do
    case socket.assigns.task_pr do
      %{pending_op: nil} ->
        socket

      %{pending_op: op, pr: pr} ->
        if same_pr?(op, pr), do: socket, else: changed(socket)
    end
  end

  # The dialog or panel is about the current pull request: same repository and number,
  # and for re-verifying the same head (the user confirms that commit).
  defp same_pr?(_op, nil), do: false

  defp same_pr?(%{kind: :reverify} = op, pr),
    do: op.pr_key == pr_key(pr) and op.head_sha == pr.head_sha

  defp same_pr?(op, pr), do: op.pr_key == pr_key(pr)

  defp changed(socket) do
    socket
    |> update_state(&%{&1 | pending_op: nil})
    |> put_flash(:error, dgettext("ui", "PR 已变化，请重新确认"))
  end

  ## Events

  @doc """
  Handles the `pr_*` events. `refresh` re-reads the task (for the history after a
  re-verification).
  """
  def handle_event(event, params, socket, refresh)

  def handle_event("pr_ask_reverify", _params, socket, _refresh) do
    with %{operation: nil, pr: %{} = pr} <- socket.assigns.task_pr,
         true <- reverify_offered?(socket) do
      open(socket, %{kind: :reverify, pr_key: pr_key(pr), head_sha: pr.head_sha, ref: pr_ref(pr)})
    else
      _ -> socket
    end
  end

  def handle_event("pr_ask_merge", _params, socket, _refresh) do
    case socket.assigns.task_pr do
      %{operation: nil, pr: %{can: %{merge_now: true}} = pr} ->
        open(socket, %{
          kind: :merge_now,
          pr_key: pr_key(pr),
          head_sha: pr.head_sha,
          ref: pr_ref(pr),
          skip_offer?: pr.can.skip_independence and pr.merge_reason == "not_independent"
        })

      _ ->
        socket
    end
  end

  def handle_event("pr_open_skip", _params, socket, _refresh) do
    with_pending(socket, :merge_now, fn
      %{skip_offer?: true} = op ->
        open(socket, Map.merge(op, %{kind: :skip, reason: "", error: nil}))

      _op ->
        socket
    end)
  end

  def handle_event("pr_skip_change", %{"skip" => %{"reason" => reason}}, socket, _refresh) do
    case socket.assigns.task_pr.pending_op do
      %{kind: :skip} = op -> put_pending(socket, %{op | reason: reason})
      _ -> socket
    end
  end

  def handle_event("pr_dismiss", %{"kind" => kind}, socket, _refresh) do
    case socket.assigns.task_pr.pending_op do
      %{kind: current} ->
        if kind == Atom.to_string(current), do: put_pending(socket, nil), else: socket

      _ ->
        socket
    end
  end

  def handle_event("pr_confirm_reverify", _params, socket, _refresh) do
    with_pending(socket, :reverify, fn op ->
      scope = socket.assigns.current_scope
      ident = socket.assigns.task.id
      {socket, operation} = start_operation(socket, op)
      opts = [expected_head_sha: operation.head_sha, expected_pull_request: expected(operation)]

      Phoenix.LiveView.start_async(socket, :pr_reverify, fn ->
        result = PullRequests.reverify(scope, ident, opts)
        test_hook({:reverified, result})
        {operation.id, result}
      end)
    end)
  end

  def handle_event("pr_merge_now", _params, socket, refresh) do
    with_pending(socket, :merge_now, fn op -> merge_now(socket, op, [], refresh) end)
  end

  def handle_event("pr_skip_submit", %{"skip" => %{"reason" => reason}}, socket, refresh) do
    with_pending(socket, :skip, fn op ->
      case validate_reason(reason) do
        {:ok, reason} ->
          merge_now(socket, op, [skip_independence: reason], refresh)

        {:error, error} ->
          put_pending(socket, %{op | reason: reason, error: error})
      end
    end)
  end

  def handle_event("pr_retry", _params, socket, refresh) do
    case socket.assigns.task_pr do
      %{operation: nil, pr: %{can: %{retry: true}} = pr} ->
        op = %{kind: :retry, pr_key: pr_key(pr), head_sha: pr.head_sha}
        {socket, operation} = start_operation(socket, op)
        result = PullRequests.retry(socket.assigns.current_scope, socket.assigns.task.id)
        socket = finish(socket, operation, result, refresh)

        if match?({:ok, _}, result) do
          Process.send_after(self(), :pr_retried, @retried_ms)
          update_state(socket, &%{&1 | retried?: true})
        else
          socket
        end

      _ ->
        socket
    end
  end

  def handle_event(_event, _params, socket, _refresh), do: socket

  @doc "Ends the 已重试 label of the retry button."
  def handle_info(:pr_retried, socket), do: update_state(socket, &%{&1 | retried?: false})

  @doc "Handles the result of `:pr_reverify` (D10)."
  def handle_async(:pr_reverify, {:ok, {id, result}}, socket, refresh) do
    case socket.assigns.task_pr.operation do
      %{id: ^id} = operation -> finish(socket, operation, result, refresh)
      _ -> socket
    end
  end

  def handle_async(:pr_reverify, {:exit, reason}, socket, refresh) do
    case socket.assigns.task_pr.operation do
      %{kind: :reverify} = operation ->
        Logger.warning("Re-verifying #{socket.assigns.task.id} exited: #{inspect(reason)}")
        finish(socket, operation, {:error, :exit}, refresh)

      _ ->
        socket
    end
  end

  ## Operations

  defp open(socket, op), do: put_pending(socket, op)

  defp put_pending(socket, op), do: update_state(socket, &%{&1 | pending_op: op})

  # The confirmation of `kind` arrived: runs `fun` when the dialog is still open for the
  # current pull request and nothing is in progress (D10); otherwise nothing is sent.
  defp with_pending(socket, kind, fun) do
    case socket.assigns.task_pr do
      %{operation: %{}} ->
        socket

      %{pending_op: %{kind: ^kind} = op, pr: pr} ->
        if same_pr?(op, pr), do: fun.(op), else: changed(socket)

      _ ->
        socket
    end
  end

  defp start_operation(socket, op) do
    state = socket.assigns.task_pr

    operation = %{
      id: state.next_id,
      kind: if(op.kind == :skip, do: :merge_now, else: op.kind),
      pr_key: op.pr_key,
      head_sha: op.head_sha
    }

    socket =
      update_state(
        socket,
        &%{&1 | operation: operation, pending_op: nil, next_id: &1.next_id + 1}
      )

    {socket, operation}
  end

  defp merge_now(socket, op, opts, refresh) do
    {socket, operation} = start_operation(socket, op)
    %{current_scope: scope, task: task} = socket.assigns
    opts = Keyword.put(opts, :expected_pull_request, expected(operation))
    finish(socket, operation, PullRequests.merge_now(scope, task.id, opts), refresh)
  end

  # The pull request the user confirmed (R7): the domain compares it with the current
  # one under its lock, so a binding changed before the page heard of it is refused.
  defp expected(%{pr_key: {full_name, number}}), do: %{repository: full_name, number: number}

  defp validate_reason(reason) do
    trimmed = String.trim(reason || "")

    cond do
      trimmed == "" -> {:error, dgettext("ui", "不能为空")}
      byte_size(trimmed) > @max_reason_bytes -> {:error, dgettext("ui", "不能超过 1000 字节")}
      true -> {:ok, trimmed}
    end
  end

  # Clears the operation, re-reads the card (and the task after a re-verification) and
  # tells the result.
  defp finish(socket, operation, result, refresh) do
    socket = update_state(socket, &%{&1 | operation: nil})
    socket = if operation.kind == :reverify, do: refresh.(socket), else: socket
    socket = reload(socket)

    case result do
      {:ok, view} ->
        put_flash(socket, :info, success_text(operation, view) <> changed_note(socket, operation))

      {:error, reason} ->
        put_flash(socket, :error, error_text(operation.kind, reason))
    end
  end

  defp success_text(%{kind: :reverify} = operation, view) do
    {full_name, number} = operation.pr_key
    sha = (view && view.verified_sha) || operation.head_sha

    dgettext("ui", "已按 %{sha} 重新验收 %{pr}",
      sha: short_sha(sha),
      pr: "#{full_name}##{number}"
    )
  end

  defp success_text(%{kind: :retry}, _view), do: dgettext("ui", "已重试")
  defp success_text(_operation, _view), do: dgettext("ui", "已提交，合并结果稍后显示在 PR 卡片")

  defp changed_note(socket, operation) do
    if pr_key(socket.assigns.task_pr.pr) == operation.pr_key,
      do: "",
      else: dgettext("ui", "（PR 已变化，卡片显示的是当前的 PR）")
  end

  @doc "Text of a refused pull request operation (D10)."
  def error_text(kind, reason)
  def error_text(_kind, :forbidden), do: dgettext("ui", "你没有权限执行此操作")
  def error_text(_kind, :not_reverifiable), do: dgettext("ui", "当前状态不能重新验收")

  def error_text(_kind, :not_pushed_by_run),
    do: dgettext("ui", "PR 的最新提交不是 Helmsman 运行推送的，不能重新验收；请在 GitHub 上处理")

  def error_text(_kind, {:head_changed, sha}),
    do: dgettext("ui", "PR 有了新提交（%{sha}），没有重新验收；请查看后重新确认", sha: short_sha(sha))

  def error_text(_kind, {:run_active, %{agent: agent}}),
    do: TransitionErrors.run_active_text(agent)

  def error_text(_kind, {:pull_request_changed, _current}),
    do: dgettext("ui", "PR 已变化，请重新确认")

  def error_text(_kind, {:invalid_status, _status}), do: dgettext("ui", "任务已不是已验收状态")

  def error_text(_kind, reason) when reason in [:not_found, :no_pull_request],
    do: dgettext("ui", "PR 不存在或已变化")

  def error_text(:reverify, {kind, _detail}) when kind in [:github_unavailable, :rate_limited],
    do: dgettext("ui", "暂时无法连接 GitHub，没有重新验收，请稍后重试")

  def error_text(:reverify, :exit), do: dgettext("ui", "重新验收失败，请重试")
  def error_text(_kind, :invalid_reason), do: dgettext("ui", "原因不能为空，且不能超过 1000 字节")

  def error_text(kind, reason) do
    Logger.warning("Pull request #{kind} failed: #{inspect(reason)}")
    dgettext("ui", "操作失败，请重试")
  end

  defp update_state(socket, fun),
    do: Phoenix.Component.assign(socket, :task_pr, fun.(socket.assigns.task_pr))

  defp put_flash(socket, kind, text), do: Phoenix.LiveView.put_flash(socket, kind, text)

  # 按当前提交重新验收 waits for the task's active runs to end (D13).
  defp reverify_offered?(socket), do: reverify_offered?(socket.assigns.task_pr, socket.assigns)

  defp reverify_offered?(%{pr: %{can: %{reverify: true}}}, %{task_runs: %{active: []}}), do: true
  defp reverify_offered?(_state, _assigns), do: false

  # Test hook: lets a test act after the domain answered, before the page gets the result.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end

  ## Rendering

  attr :state, :map, required: true
  attr :task, :map, required: true
  attr :runs, :map, required: true

  @doc "The card (D8)."
  def card(assigns) do
    state = assigns.state

    assigns =
      assign(assigns,
        busy: state.operation && state.operation.kind,
        reverify: reverify_offered?(state, %{task_runs: assigns.runs})
      )

    ~H"""
    <GitHubComponents.pr_card
      pr={@state.pr}
      repository={@state.repository}
      task_status={@task.status}
      busy={@busy}
      reverify={@reverify}
      retried={@state.retried?}
    />
    """
  end

  attr :state, :map, required: true

  @doc "The confirmation dialogs and the 跳过独立性并合并 panel (D10); always rendered."
  def dialogs(assigns) do
    op = assigns.state.pending_op
    assigns = assign(assigns, op: op, kind: op && op.kind)

    ~H"""
    <.confirm_dialog
      id="pr-reverify-confirm"
      show={@kind == :reverify}
      title={if(@kind == :reverify, do: dgettext("ui", "按当前提交重新验收？"), else: "")}
      confirm_label={dgettext("ui", "重新验收")}
      on_confirm={JS.push("pr_confirm_reverify")}
      on_cancel={JS.push("pr_dismiss", value: %{kind: "reverify"})}
    >
      {if(@kind == :reverify,
        do:
          dgettext(
            "ui",
            "将以你的名义验收 %{sha}，并记一条评审意见；之后按这个提交检查独立性、CI 并合并。",
            sha: short_sha(@op.head_sha)
          )
      )}
    </.confirm_dialog>
    <.confirm_dialog
      id="pr-merge-confirm"
      show={@kind == :merge_now}
      title={if(@kind == :merge_now, do: dgettext("ui", "立即合并 %{pr}？", pr: @op.ref), else: "")}
      confirm_label={
        if(@kind == :merge_now and @op.skip_offer?,
          do: dgettext("ui", "填写原因并合并"),
          else: dgettext("ui", "立即合并")
        )
      }
      on_confirm={
        JS.push(if(@kind == :merge_now and @op.skip_offer?, do: "pr_open_skip", else: "pr_merge_now"))
      }
      on_cancel={JS.push("pr_dismiss", value: %{kind: "merge_now"})}
    >
      {cond do
        @kind != :merge_now ->
          nil

        @op.skip_offer? ->
          dgettext("ui", "验收不独立。作为所有者，你可以填写原因跳过独立性检查")

        true ->
          dgettext(
            "ui",
            "放行项目的合并策略；CI、头部未变、无运行中、推送链等其他前提照常检查，满足后才合并。结果稍后显示在这里。"
          )
      end}
    </.confirm_dialog>
    <.skip_panel op={if(@kind == :skip, do: @op)} />
    """
  end

  attr :op, :map, default: nil

  defp skip_panel(%{op: nil} = assigns) do
    ~H"""
    <.side_panel
      id="pr-skip-panel"
      show={false}
      title=""
      on_cancel={JS.push("pr_dismiss", value: %{kind: "skip"})}
    >
      <div />
    </.side_panel>
    """
  end

  defp skip_panel(assigns) do
    ~H"""
    <.side_panel
      id="pr-skip-panel"
      show
      dirty
      title={dgettext("ui", "跳过独立性并合并 %{pr}", pr: @op.ref)}
      focus="#pr-skip-reason"
      on_cancel={JS.push("pr_dismiss", value: %{kind: "skip"})}
    >
      <p class="mb-4 text-body text-fg-muted">{dgettext("ui", "原因会以系统身份记入任务的 Feedback")}</p>
      <.form
        for={%{}}
        as={:skip}
        id="pr-skip-form"
        phx-change="pr_skip_change"
        phx-submit="pr_skip_submit"
      >
        <.input
          type="textarea"
          id="pr-skip-reason"
          name="skip[reason]"
          label={dgettext("ui", "原因")}
          value={@op.reason}
          errors={List.wrap(@op.error)}
          rows="4"
          maxlength="1000"
          required
        />
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button id="pr-skip-submit" type="submit" form="pr-skip-form" variant="primary">
            {dgettext("ui", "合并")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end

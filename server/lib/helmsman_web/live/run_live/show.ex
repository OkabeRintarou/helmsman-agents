defmodule HelmsmanWeb.RunLive.Show do
  @moduledoc """
  `/w/:slug/runs/:id` (spec web-runs 运行页, design D10): the run's log
  (`HelmsmanWeb.RunLog`) and its properties, with 停止 / 重试 by permission. A run of
  another workspace, or none, is a 404. The log keeps the summary current.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.RunComponents

  alias HelmsmanWeb.{RunActions, RunData, RunLog, Url}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {id, ""} <- Integer.parse(id),
         {:ok, run} <- RunData.run(scope, id) do
      title = dgettext("ui", "运行 #%{id} · %{agent}", id: run.id, agent: run.agent)

      socket =
        socket
        |> assign(page_title: title, fallback_run: run)
        |> RunLog.init()
        |> RunActions.init()

      if connected?(socket),
        do: {:ok, RunLog.open(socket, run.id)},
        else: {:ok, assign(socket, :run_log, %{id: run.id, state: :loading, run: run})}
    else
      _ -> raise HelmsmanWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("run_log_" <> _ = event, params, socket),
    do: {:noreply, RunLog.handle_event(event, params, socket)}

  def handle_event(event, params, socket)
      when event in ~w(ask_cancel_run dismiss_cancel_run cancel_run retry_run),
      do: {:noreply, RunActions.handle_event(event, params, socket, &reload/1)}

  defp reload(socket) do
    %{run_log: log, current_scope: scope} = socket.assigns

    case RunData.run(scope, log.id) do
      {:ok, run} -> assign(socket, :run_log, %{log | run: run})
      _ -> socket
    end
  end

  @impl true
  def handle_info(message, socket) do
    case RunLog.handle_info(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :ignore -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    run = assigns.run_log.run || assigns.fallback_run
    scope = assigns.current_scope

    assigns =
      assign(assigns,
        run: run,
        slug: scope.workspace.slug,
        can_cancel?: cancellable?(scope, run),
        can_retry?: retryable?(scope, run)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "运行 #%{id}", id: @run.id)}>
          <:crumb navigate={"/w/#{@slug}/agents"}>Agents</:crumb>
          <:crumb navigate={Url.agent_path(@slug, @run.agent)}>{@run.agent}</:crumb>
          <:actions>
            <.button
              :if={@can_cancel?}
              id="run-cancel"
              size="sm"
              icon="lucide-square"
              phx-click="ask_cancel_run"
              phx-value-id={@run.id}
            >
              {dgettext("ui", "停止")}
            </.button>
            <.button
              :if={@can_retry?}
              id="run-retry"
              size="sm"
              icon="lucide-rotate-ccw"
              phx-click="retry_run"
              phx-value-id={@run.id}
            >
              {dgettext("ui", "重试")}
            </.button>
          </:actions>
        </.page_header>
      </:header>
      <div class="grid gap-6 px-4 py-4 lg:grid-cols-[minmax(0,1fr)_320px] lg:px-6">
        <section
          class="flex min-h-[60dvh] min-w-0 flex-col"
          aria-label={dgettext("ui", "执行记录")}
        >
          <RunLog.log log={@run_log} events={@streams.run_events} scope={@current_scope} />
        </section>
        <aside id="run-properties" aria-label={dgettext("ui", "属性")}>
          <.run_properties run={@run} slug={@slug} />
        </aside>
      </div>
      <RunActions.dialog stop_run={@stop_run} />
    </Layouts.app>
    """
  end

  attr :run, :map, required: true
  attr :slug, :string, required: true

  defp run_properties(assigns) do
    ~H"""
    <.property_list>
      <.property_row label={dgettext("ui", "任务")} data-task>
        <.task_id_link :if={@run.task} ident={@run.task} workspace={@slug} />
        <span :if={!@run.task and autopilot_run?(@run)} class="text-fg-muted" data-no-task>
          {dgettext("ui", "无任务（自动化）")}
        </span>
      </.property_row>
      <.property_row :if={@run[:squad]} label={dgettext("ui", "小队")} data-squad>
        <.link navigate={Url.squad_path(@slug, @run.squad.name)} class="text-fg hover:underline">
          {@run.squad.name}
        </.link>
      </.property_row>
      <.property_row label="Agent" data-agent>
        <.link navigate={Url.agent_path(@slug, @run.agent)} class="text-fg hover:underline">
          {@run.agent}
        </.link>
      </.property_row>
      <.property_row
        :if={@run[:provider_account_name]}
        label={dgettext("ui", "供应商账号")}
        value={@run.provider_account_name}
        data-provider-account
      />
      <.property_row label="lane" value={@run.lane} />
      <.property_row label={dgettext("ui", "状态")} data-status>
        <.run_status_badge status={@run.status} />
      </.property_row>
      <.property_row label={dgettext("ui", "触发")} data-triggers>
        <ul class="flex flex-col gap-0.5">
          <li :for={t <- @run.triggers} class="text-body text-fg">
            <.link
              :if={autopilot_path(t, @slug)}
              navigate={autopilot_path(t, @slug)}
              class="hover:underline"
              data-autopilot-link
            >
              {trigger_label(t)}
            </.link>
            <span :if={!autopilot_path(t, @slug)}>{trigger_label(t)}</span>
            <span :if={t[:at]} class="text-caption text-fg-muted">
              {Calendar.strftime(t.at, "%m-%d %H:%M")}
            </span>
            <span :if={t[:instructions]} class="block text-caption text-fg-muted">
              {dgettext("ui", "说明：")}{t.instructions}
            </span>
          </li>
        </ul>
      </.property_row>
      <.property_row
        :if={@run[:initiator]}
        label={dgettext("ui", "授权来源")}
        value={@run.initiator[:name]}
      />
      <.property_row
        :if={@run[:attempt]}
        label={dgettext("ui", "尝试")}
        value={dgettext("ui", "第 %{n} 次", n: @run.attempt)}
      />
      <.property_row label={dgettext("ui", "守护进程")} value={@run[:daemon]} data-daemon />
      <.property_row label={dgettext("ui", "排队")}>
        <.relative_time id="run-queued-at" at={@run.inserted_at} class="text-fg" />
      </.property_row>
      <.property_row :if={@run[:claimed_at]} label={dgettext("ui", "领取")}>
        <.relative_time id="run-claimed-at" at={@run.claimed_at} class="text-fg" />
      </.property_row>
      <.property_row :if={@run[:started_at]} label={dgettext("ui", "开始")}>
        <.relative_time id="run-started-at" at={@run.started_at} class="text-fg" />
      </.property_row>
      <.property_row :if={@run[:finished_at]} label={dgettext("ui", "结束")}>
        <.relative_time id="run-finished-at" at={@run.finished_at} class="text-fg" />
      </.property_row>
      <.property_row label={dgettext("ui", "耗时")} value={duration_text(@run)} />
      <.property_row label={dgettext("ui", "用量")} value={usage_text(@run[:usage])} />
      <.property_row
        :if={@run.failure_reason}
        label={dgettext("ui", "失败原因")}
        value={failure_label(@run.failure_reason)}
      />
      <.property_row
        :if={@run.status in ["failed", "cancelled"] and autopilot_run?(@run)}
        label={dgettext("ui", "重试")}
        value={not_retryable_autopilot()}
        data-not-retryable
      />
      <.property_row
        :if={@run[:retry_of_id] || @run[:retry_run_id]}
        label={dgettext("ui", "重试")}
      >
        <.link
          :if={@run[:retry_of_id]}
          navigate={"/w/#{@slug}/runs/#{@run.retry_of_id}"}
          class="hover:underline"
        >
          {dgettext("ui", "重试自 #%{id}", id: @run.retry_of_id)}
        </.link>
        <.link
          :if={@run[:retry_run_id]}
          navigate={"/w/#{@slug}/runs/#{@run.retry_run_id}"}
          class="hover:underline"
        >
          {dgettext("ui", "已重试 → #%{id}", id: @run.retry_run_id)}
        </.link>
      </.property_row>
    </.property_list>
    """
  end
end

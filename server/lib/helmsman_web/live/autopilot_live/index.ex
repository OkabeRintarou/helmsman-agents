defmodule HelmsmanWeb.AutopilotLive.Index do
  @moduledoc """
  `/w/:slug/autopilots` (spec web-autopilots 自动化列表页, design D8): every autopilot of
  the workspace with its mode, target, trigger, next run, last result, warnings and the
  enable switch; the new-autopilot panel (`?panel=new-autopilot`).

  Subscribes to `workspace:<id>:autopilots`: `{:autopilot, id}` and
  `{:autopilot_run, id, _}` re-read that row (`get/2`; `not_found` removes it).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AutopilotComponents

  alias HelmsmanWeb.{AutopilotData, AutopilotForm, Url}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: AutopilotData.subscribe(scope.workspace.id)

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "自动化"),
       can_create?: scope.role in [:owner, :admin, :member],
       browser_tz: browser_timezone(socket),
       ids: MapSet.new(),
       uri: nil,
       confirm: nil,
       autopilot_form: nil,
       form_gen: 0
     )
     |> stream_configure(:autopilots, dom_id: &"autopilot-#{&1.id}")
     |> stream(:autopilots, [])
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    socket = assign(socket, uri: if(query, do: "#{path}?#{query}", else: path))

    open? = params["panel"] == "new-autopilot" and socket.assigns.can_create?
    {:noreply, open_form(socket, open?)}
  end

  defp open_form(socket, false), do: assign(socket, :autopilot_form, nil)
  defp open_form(%{assigns: %{autopilot_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    gen = socket.assigns.form_gen + 1
    scope = socket.assigns.current_scope

    assign(socket,
      form_gen: gen,
      autopilot_form: AutopilotForm.new(scope, gen, socket.assigns.browser_tz)
    )
  end

  defp load(socket) do
    autopilots =
      case AutopilotData.list(socket.assigns.current_scope) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(:ids, MapSet.new(autopilots, & &1.id))
    |> stream(:autopilots, autopilots, reset: true)
  end

  defp reload_row(socket, id) do
    case AutopilotData.get(socket.assigns.current_scope, id) do
      {:ok, view} ->
        socket
        |> assign(:ids, MapSet.put(socket.assigns.ids, view.id))
        |> stream_insert(:autopilots, view)

      {:error, _} ->
        socket
        |> assign(:ids, MapSet.delete(socket.assigns.ids, id))
        |> stream_delete_by_dom_id(:autopilots, "autopilot-#{id}")
    end
  end

  ## Events

  @impl true
  def handle_event("ap_form_" <> _ = event, params, socket) do
    case AutopilotForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_text(view, socket.assigns.browser_tz))
         |> push_navigate(to: show_path(socket.assigns.current_scope, view.id))}

      {:closed, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      result ->
        result
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, id} <- parse_id(id),
         {:ok, view} <- AutopilotData.get(scope, id) do
      cond do
        view.enabled and view.permissions.disable ->
          {:noreply, socket |> run(&AutopilotData.disable/2, id, :disabled) |> reload_row(id)}

        not view.enabled and view.permissions.manage and AutopilotData.own?(view, scope) ->
          {:noreply, socket |> run(&AutopilotData.enable/2, id, :enabled) |> reload_row(id)}

        not view.enabled and view.permissions.manage ->
          confirm = %{id: id, name: view.name, initiator: initiator_name(view)}
          {:noreply, assign(socket, :confirm, confirm)}

        true ->
          {:noreply, reload_row(socket, id)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_enable", %{"id" => id}, socket) do
    socket = assign(socket, :confirm, nil)

    case parse_id(id) do
      {:ok, id} ->
        {:noreply, socket |> run(&AutopilotData.enable/2, id, :enabled) |> reload_row(id)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  defp run(socket, fun, id, done) do
    case fun.(socket.assigns.current_scope, id) do
      {:ok, view} -> put_flash(socket, :info, done_text(done, view.name))
      {:error, reason} -> put_flash(socket, :error, error_text(reason))
    end
  end

  defp done_text(:enabled, name), do: dgettext("ui", "已启用 %{name}", name: name)
  defp done_text(:disabled, name), do: dgettext("ui", "已停用 %{name}", name: name)

  defp error_text(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp error_text(:not_found), do: dgettext("ui", "这个自动化已不存在")
  defp error_text(_), do: dgettext("ui", "操作失败，请重试")

  @impl true
  def handle_info({:autopilot, id}, socket), do: {:noreply, reload_row(socket, id)}

  def handle_info({:autopilot_run, id, _record_id}, socket),
    do: {:noreply, reload_row(socket, id)}

  ## Helpers

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp initiator_name(%{initiator: %{name: name}}), do: name
  defp initiator_name(_view), do: nil

  defp show_path(scope, id), do: "/w/#{scope.workspace.slug}/autopilots/#{id}"

  @doc "「已保存 <名字>」, with the next run when there is one."
  def saved_text(view, tz) do
    case view.next_run_at do
      %DateTime{} = at ->
        dgettext("ui", "已保存 %{name}，下一次：%{at}",
          name: view.name,
          at: local_time(at, tz, [])
        )

      _ ->
        dgettext("ui", "已保存 %{name}", name: view.name)
    end
  end

  @doc "Text of the confirmation before enabling an autopilot authorized by someone else."
  def enable_text(%{initiator: name}) when is_binary(name),
    do: dgettext("ui", "启用后，定时与 webhook 触发改为以你的权限运行（当前以 %{name} 的权限运行）。", name: name)

  def enable_text(_confirm), do: dgettext("ui", "启用后，定时与 webhook 触发以你的权限运行。")

  # Why the switch is read-only for the current user (nil when it can be flipped).
  defp switch_reason(view, scope) do
    cond do
      view.enabled and view.permissions.disable -> nil
      not view.enabled and view.permissions.manage -> nil
      scope.role == :viewer -> dgettext("ui", "只读成员不能启用或停用自动化")
      true -> dgettext("ui", "你无权触发 %{target}", target: view.agent && view.agent.name)
    end
  end

  defp next_run(view) do
    if view.enabled and match?(%DateTime{}, view.next_run_at), do: view.next_run_at
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        slug: assigns.current_scope.workspace.slug,
        new_path: Url.put_params(assigns.uri || "", %{panel: "new-autopilot"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"]),
        empty?: MapSet.size(assigns.ids) == 0
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "自动化")}>
          <:actions>
            <.button
              :if={@can_create?}
              id="autopilots-new"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_path}
            >
              {dgettext("ui", "新建自动化")}
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="px-4 py-4 lg:px-6">
        <div :if={@empty?} id="autopilots-empty">
          <.empty_state
            icon="lucide-timer"
            title={dgettext("ui", "还没有自动化")}
            description={
              dgettext(
                "ui",
                "自动化把一段说明交给 Agent 或小队去做：可以按计划定时触发、手动立即运行，或由外部系统通过 webhook 触发。「建任务」模式在项目里建一张任务；「仅运行」模式不建任务，Agent 看完写结论。"
              )
            }
          >
            <:action :if={@can_create?}>
              <.button variant="primary" size="sm" icon="lucide-plus" patch={@new_path}>
                {dgettext("ui", "新建自动化")}
              </.button>
            </:action>
          </.empty_state>
        </div>

        <.data_table
          :if={!@empty?}
          id="autopilots"
          rows={@streams.autopilots}
          label={dgettext("ui", "自动化")}
          rich
          row_click={&JS.navigate("/w/#{@slug}/autopilots/#{&1.id}")}
        >
          <:col :let={a} label={dgettext("ui", "名字")} class="w-[22%]">
            <div class="flex min-w-0 flex-col">
              <.link
                navigate={"/w/#{@slug}/autopilots/#{a.id}"}
                class="truncate font-medium text-fg"
                data-name
              >
                {a.name}
              </.link>
              <span class="flex min-w-0 items-center gap-1.5 text-caption text-fg-muted">
                <span data-mode>{mode_label(a.mode)}</span>
                <span
                  :if={!a.enabled && a.disabled_reason}
                  class="truncate text-warning-fg"
                  data-disabled-reason
                >
                  · {disabled_text(a.disabled_reason)}
                </span>
              </span>
            </div>
          </:col>
          <:col :let={a} label={dgettext("ui", "目标")}>
            <span data-target><.actor_chip actor={target_actor(a.agent)} /></span>
          </:col>
          <:col :let={a} label={dgettext("ui", "触发方式")} class="w-[22%]">
            <span class="flex min-w-0 items-center gap-1.5" data-trigger>
              <span class="truncate">{trigger_text(a)}</span>
              <.icon
                :if={a.webhook.enabled}
                name="lucide-webhook"
                label="webhook"
                class="size-4 shrink-0 text-fg-muted"
              />
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "下次运行")} secondary>
            <span class="flex flex-col text-caption" data-next-run>
              <span :if={next_run(a)} class="text-fg">
                {local_time(next_run(a), @browser_tz, [])}
              </span>
              <span :if={next_run(a)} class="text-fg-muted">{future_text(next_run(a))}</span>
              <span :if={!next_run(a)} class="text-fg-subtle">—</span>
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "最近结果")} secondary>
            <span :if={a.last_run} class="flex items-center gap-1.5" data-last-run>
              <.tooltip :if={reason_text(a.last_run.reason)} text={reason_text(a.last_run.reason)}>
                <.record_badge status={a.last_run.status} />
              </.tooltip>
              <.record_badge :if={!reason_text(a.last_run.reason)} status={a.last_run.status} />
              <.relative_time
                id={"autopilot-#{a.id}-last-run"}
                at={a.last_run.finished_at || a.last_run.inserted_at}
                class="text-caption text-fg-muted"
              />
            </span>
          </:col>
          <:col :let={a} label="" class="w-10">
            <.tooltip
              :if={a.warnings != []}
              id={"autopilot-#{a.id}-warnings"}
              text={
                dgettext("ui", "下一次触发会失败：%{reasons}",
                  reasons: Enum.map_join(a.warnings, "、", &warning_text/1)
                )
              }
            >
              <span role="img" aria-label={dgettext("ui", "下一次触发会失败")} data-warning>
                <.icon name="lucide-triangle-alert" class="size-4 text-warning" />
              </span>
            </.tooltip>
          </:col>
          <:col :let={a} label={dgettext("ui", "启用")} class="w-16">
            <.enable_switch
              id={"autopilot-#{a.id}-toggle"}
              autopilot_id={a.id}
              on={a.enabled}
              reason={switch_reason(a, @current_scope)}
            />
          </:col>
        </.data_table>
      </div>

      <AutopilotForm.panel
        :if={@can_create?}
        form={@autopilot_form}
        scope={@current_scope}
        close_path={@close_path}
      />

      <.confirm_dialog
        id="autopilot-enable-dialog"
        show={@confirm != nil}
        title={(@confirm && dgettext("ui", "启用 %{name}？", name: @confirm.name)) || ""}
        confirm_label={dgettext("ui", "启用")}
        on_confirm="confirm_enable"
        confirm_value={(@confirm && %{id: @confirm.id}) || %{}}
        on_cancel={JS.push("dismiss")}
      >
        {enable_text(@confirm)}
      </.confirm_dialog>
    </Layouts.app>
    """
  end
end

defmodule HelmsmanWeb.AutopilotLive.Show do
  @moduledoc """
  `/w/:slug/autopilots/:id` (spec web-autopilots 自动化详情页, 立即运行, Webhook 令牌, 触发历史,
  自动化页实时刷新; design D11, D12): configuration, disabled and warning banners, actions
  by `permissions`, the webhook section, the trigger history (50 per page, 加载更多 with
  `before_id`) and the panels `?panel=edit`, `?panel=run-now` and `?record=<id>`.

  Realtime (D11): `{:autopilot, id}` re-reads the configuration (`not_found` → back to
  the list with 「自动化已被删除」); `{:autopilot_run, id, record_id}` reads that record:
  a loaded one (any page, tracked in a `MapSet`) is updated in place, a newer one goes
  on top, an older one is left to 加载更多 (the cursor is the oldest loaded id), a deleted
  one is removed. The first page is never re-read.

  The webhook token exists only in `@token` while its dialog is open (D12).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AutopilotComponents

  alias HelmsmanWeb.{AutopilotData, AutopilotForm, Url}
  alias HelmsmanWeb.AutopilotLive.Index

  @page 50
  @max_note 4096

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    socket =
      assign(socket,
        page_title: dgettext("ui", "自动化"),
        browser_tz: browser_timezone(socket),
        uri: nil
      )

    scope = socket.assigns.current_scope

    with {:ok, id} <- parse_id(raw_id),
         {:ok, view} <- AutopilotData.get(scope, id) do
      if connected?(socket), do: AutopilotData.subscribe(scope.workspace.id)

      {:ok,
       socket
       |> assign(
         id: id,
         loaded: MapSet.new(),
         newest: nil,
         oldest: nil,
         more?: false,
         record: nil,
         run_panel: nil,
         run_result: nil,
         autopilot_form: nil,
         form_gen: 0,
         confirm: nil,
         token: nil,
         deleted?: false
       )
       |> put_autopilot(view)
       |> stream_configure(:records, dom_id: &"record-#{&1.id}")
       |> stream(:records, [])
       |> load_history()}
    else
      _ -> raise HelmsmanWeb.NotFoundError
    end
  end

  defp put_autopilot(socket, view) do
    upcoming =
      with true <- view.enabled and is_binary(view.cron),
           {:ok, times} <- AutopilotData.preview(view.cron, view.timezone, 5) do
        times
      else
        _ -> []
      end

    assign(socket, autopilot: view, page_title: view.name, upcoming: upcoming)
  end

  defp load_history(socket) do
    scope = socket.assigns.current_scope

    case AutopilotData.history(scope, socket.assigns.id, before_id: nil, limit: @page) do
      {:ok, %{records: records} = page} ->
        ids = Enum.map(records, & &1.id)

        socket
        |> assign(
          loaded: MapSet.new(ids),
          newest: Enum.max(ids, fn -> nil end),
          oldest: Enum.min(ids, fn -> nil end),
          more?: page.more?
        )
        |> stream(:records, records, reset: true)

      _ ->
        socket
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    perms = socket.assigns.autopilot.permissions

    {:noreply,
     socket
     |> assign(:uri, if(query, do: "#{path}?#{query}", else: path))
     |> open_form(params["panel"] == "edit" and perms.manage)
     |> open_run_panel(params["panel"] == "run-now" and perms.run)
     |> open_record(params["record"])}
  end

  defp open_form(socket, false), do: assign(socket, :autopilot_form, nil)
  defp open_form(%{assigns: %{autopilot_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    gen = socket.assigns.form_gen + 1
    %{current_scope: scope, autopilot: view, browser_tz: tz} = socket.assigns
    assign(socket, form_gen: gen, autopilot_form: AutopilotForm.edit(scope, gen, view, tz))
  end

  defp open_run_panel(socket, false), do: assign(socket, :run_panel, nil)
  defp open_run_panel(%{assigns: %{run_panel: %{}}} = socket, true), do: socket
  defp open_run_panel(socket, true), do: assign(socket, :run_panel, %{note: "", error: nil})

  defp open_record(socket, nil), do: assign(socket, :record, nil)

  defp open_record(socket, raw) do
    with {:ok, id} <- parse_id(raw),
         {:ok, record} <- AutopilotData.get_run(socket.assigns.current_scope, id) do
      assign(socket, :record, record)
    else
      _ -> assign(socket, :record, nil)
    end
  end

  ## Events

  @impl true
  def handle_event("ap_form_" <> _ = event, params, socket) do
    case AutopilotForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        {:noreply,
         socket
         |> put_autopilot(view)
         |> assign(:autopilot_form, nil)
         |> put_flash(:info, Index.saved_text(view, socket.assigns.browser_tz))
         |> push_patch(to: drop(socket, "panel"))}

      {:closed, message, socket} ->
        {:noreply, socket |> put_flash(:error, message) |> push_patch(to: drop(socket, "panel"))}

      result ->
        result
    end
  end

  def handle_event("run_now_change", %{"run" => %{"note" => note}}, socket) do
    {:noreply, assign(socket, :run_panel, %{note: note, error: note_error(note)})}
  end

  def handle_event("run_now_submit", %{"run" => %{"note" => note}}, socket) do
    case note_error(note) do
      nil -> {:noreply, run_now(socket, note)}
      error -> {:noreply, assign(socket, :run_panel, %{note: note, error: error})}
    end
  end

  def handle_event("disable", _params, socket),
    do: {:noreply, mutate(socket, &AutopilotData.disable/2, :disabled)}

  def handle_event("enable", _params, socket) do
    if AutopilotData.own?(socket.assigns.autopilot, socket.assigns.current_scope),
      do: {:noreply, mutate(socket, &AutopilotData.enable/2, :enabled)},
      else: {:noreply, assign(socket, :confirm, :enable)}
  end

  def handle_event("ask_" <> what, _params, socket)
      when what in ~w(delete rotate disable_webhook),
      do: {:noreply, assign(socket, :confirm, String.to_existing_atom(what))}

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("confirm_enable", _params, socket),
    do: {:noreply, socket |> assign(:confirm, nil) |> mutate(&AutopilotData.enable/2, :enabled)}

  def handle_event("delete", _params, socket) do
    %{current_scope: scope, autopilot: view} = socket.assigns
    socket = assign(socket, :confirm, nil)

    case AutopilotData.delete(scope, view.id) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}

      _deleted ->
        {:noreply,
         socket
         |> assign(:deleted?, true)
         |> put_flash(:info, dgettext("ui", "已删除 %{name}", name: view.name))
         |> push_navigate(to: list_path(scope))}
    end
  end

  def handle_event("enable_webhook", _params, socket),
    do: {:noreply, webhook_token(socket, &AutopilotData.enable_webhook/2, false)}

  def handle_event("rotate", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> webhook_token(&AutopilotData.rotate_webhook_token/2, true)}

  def handle_event("disable_webhook", _params, socket) do
    socket = assign(socket, :confirm, nil)
    %{current_scope: scope, autopilot: view} = socket.assigns

    case AutopilotData.disable_webhook(scope, view.id) do
      {:ok, view} ->
        {:noreply,
         socket |> put_autopilot(view) |> put_flash(:info, dgettext("ui", "已关闭 webhook"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("close_token", _params, socket), do: {:noreply, assign(socket, :token, nil)}

  def handle_event("dismiss_result", _params, socket),
    do: {:noreply, assign(socket, :run_result, nil)}

  def handle_event("load_more", _params, %{assigns: %{more?: true}} = socket) do
    %{current_scope: scope, id: id, oldest: oldest} = socket.assigns

    case AutopilotData.history(scope, id, before_id: oldest, limit: @page) do
      {:ok, %{records: records} = page} ->
        records = Enum.reject(records, &MapSet.member?(socket.assigns.loaded, &1.id))
        ids = Enum.map(records, & &1.id)

        {:noreply,
         socket
         |> assign(
           loaded: MapSet.union(socket.assigns.loaded, MapSet.new(ids)),
           oldest: Enum.min([oldest | ids], fn -> oldest end),
           more?: page.more?
         )
         |> stream(:records, records, at: -1)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  defp note_error(note) do
    if byte_size(note) > @max_note, do: dgettext("ui", "不能超过 4 KB"), else: nil
  end

  defp run_now(socket, note) do
    %{current_scope: scope, autopilot: view} = socket.assigns

    case AutopilotData.run_now(scope, view.id, note) do
      {:ok, record} ->
        socket
        |> upsert(record)
        |> assign(run_panel: nil, run_result: run_result(record))
        |> push_patch(to: drop(socket, "panel"))

      {:error, %Ecto.Changeset{} = cs} ->
        error = cs |> HelmsmanWeb.FormErrors.messages() |> Map.values() |> List.flatten()
        assign(socket, :run_panel, %{note: note, error: Enum.join(error, "；")})

      {:error, reason} ->
        socket
        |> assign(:run_panel, nil)
        |> put_flash(:error, error_text(reason))
        |> push_patch(to: drop(socket, "panel"))
    end
  end

  defp run_result(record) do
    {kind, text} =
      case to_string(record.status) do
        "started" ->
          {:info, dgettext("ui", "已开始")}

        "pending" ->
          {:info, dgettext("ui", "已排队：上一次还在进行，结束后执行这一次")}

        "skipped" ->
          {:warning, dgettext("ui", "上一次还在进行，已跳过这一次")}

        "succeeded" ->
          {:info, dgettext("ui", "已完成")}

        _ ->
          {:danger, dgettext("ui", "立即运行失败：%{reason}", reason: reason_text(record.reason) || "—")}
      end

    %{kind: kind, text: text, task: record[:task], run_id: record[:run_id], id: record.id}
  end

  defp mutate(socket, fun, done) do
    %{current_scope: scope, autopilot: view} = socket.assigns

    case fun.(scope, view.id) do
      {:ok, view} ->
        text =
          if done == :enabled,
            do: dgettext("ui", "已启用 %{name}", name: view.name),
            else: dgettext("ui", "已停用 %{name}", name: view.name)

        socket |> put_autopilot(view) |> put_flash(:info, text)

      {:error, reason} ->
        put_flash(socket, :error, error_text(reason))
    end
  end

  defp webhook_token(socket, fun, rotated?) do
    %{current_scope: scope, autopilot: view} = socket.assigns

    case fun.(scope, view.id) do
      {:ok, %{token: token, url: url, autopilot: view}} ->
        socket
        |> assign(:token, %{token: token, url: url, rotated?: rotated?})
        |> put_autopilot(view)

      {:error, reason} ->
        put_flash(socket, :error, error_text(reason))
    end
  end

  defp error_text(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp error_text(:not_found), do: dgettext("ui", "这个自动化已不存在")
  defp error_text(_), do: dgettext("ui", "操作失败，请重试")

  ## Realtime

  @impl true
  def handle_info({:autopilot, id}, %{assigns: %{id: id, deleted?: false}} = socket) do
    case AutopilotData.get(socket.assigns.current_scope, id) do
      {:ok, view} ->
        {:noreply, put_autopilot(socket, view)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:deleted?, true)
         |> put_flash(:error, dgettext("ui", "自动化已被删除"))
         |> push_navigate(to: list_path(socket.assigns.current_scope))}
    end
  end

  def handle_info(
        {:autopilot_run, id, record_id},
        %{assigns: %{id: id, deleted?: false}} = socket
      ) do
    case AutopilotData.get_run(socket.assigns.current_scope, record_id) do
      {:ok, record} -> {:noreply, upsert(socket, record)}
      {:error, _} -> {:noreply, remove(socket, record_id)}
    end
  end

  # A loaded record is updated in place; a newer one goes on top; an older one is left
  # for 加载更多.
  defp upsert(socket, record) do
    %{loaded: loaded, newest: newest} = socket.assigns

    socket =
      cond do
        MapSet.member?(loaded, record.id) ->
          stream_insert(socket, :records, record)

        newest == nil or record.id > newest ->
          socket
          |> assign(
            loaded: MapSet.put(loaded, record.id),
            newest: record.id,
            oldest: socket.assigns.oldest || record.id
          )
          |> stream_insert(:records, record, at: 0)

        true ->
          socket
      end

    if match?(%{id: id} when id == record.id, socket.assigns.record),
      do: assign(socket, :record, Map.merge(socket.assigns.record, record)),
      else: socket
  end

  defp remove(socket, record_id) do
    socket =
      if MapSet.member?(socket.assigns.loaded, record_id),
        do:
          socket
          |> assign(:loaded, MapSet.delete(socket.assigns.loaded, record_id))
          |> stream_delete_by_dom_id(:records, "record-#{record_id}"),
        else: socket

    if match?(%{id: ^record_id}, socket.assigns.record),
      do: assign(socket, :record, nil),
      else: socket
  end

  ## Helpers

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp list_path(scope), do: "/w/#{scope.workspace.slug}/autopilots"
  defp drop(socket, key), do: Url.drop_params(socket.assigns.uri || "", [key])

  defp curl(url, token) do
    Enum.join(
      [
        "curl -X POST #{url}",
        ~s|  -H "Authorization: Bearer #{token}"|,
        ~s|  -H "X-Delivery-Id: $(uuidgen)"|,
        ~s|  -H "Content-Type: application/json"|,
        ~s|  -d '{"ref": "main"}'|
      ],
      " \\\n"
    )
  end

  defp payload_view(nil), do: nil

  # Only the domain's wrapper of a body that is not JSON (exactly these two keys); a JSON
  # body that happens to have a "raw" key is shown as JSON (code-review-1 P2-2).
  defp payload_view(%{"raw" => raw, "truncated" => truncated} = payload)
       when is_binary(raw) and is_boolean(truncated) and map_size(payload) == 2,
       do: {:raw, raw, truncated}

  defp payload_view(payload), do: {:json, Jason.encode!(payload, pretty: true)}

  defp more_items(view) do
    p = view.permissions

    [
      p.disable && view.enabled &&
        %{
          id: "autopilot-disable",
          label: dgettext("ui", "停用"),
          icon: "lucide-pause",
          on_select: "disable"
        },
      p.manage && !view.enabled &&
        %{
          id: "autopilot-enable",
          label: dgettext("ui", "启用"),
          icon: "lucide-play",
          on_select: "enable"
        },
      p.disable &&
        %{
          id: "autopilot-delete",
          label: dgettext("ui", "删除"),
          icon: "lucide-trash",
          danger: true,
          on_select: "ask_delete"
        }
    ]
    |> Enum.filter(& &1)
  end

  defp confirm_spec(:delete, view),
    do: %{
      title: dgettext("ui", "删除 %{name}？", name: view.name),
      body: dgettext("ui", "删除后不再触发，触发历史一并删除；已建的任务与运行保留。"),
      label: dgettext("ui", "删除"),
      event: "delete",
      danger: true
    }

  defp confirm_spec(:rotate, _view),
    do: %{
      title: dgettext("ui", "轮换 webhook 令牌？"),
      body: dgettext("ui", "旧令牌立即失效，使用它的外部系统需要换成新令牌；之后 webhook 触发以你的权限运行。"),
      label: dgettext("ui", "轮换令牌"),
      event: "rotate",
      danger: true
    }

  defp confirm_spec(:disable_webhook, _view),
    do: %{
      title: dgettext("ui", "关闭 webhook？"),
      body: dgettext("ui", "关闭后令牌立即失效，外部系统不能再触发这个自动化。"),
      label: dgettext("ui", "关闭 webhook"),
      event: "disable_webhook",
      danger: true
    }

  defp confirm_spec(:enable, view),
    do: %{
      title: dgettext("ui", "启用 %{name}？", name: view.name),
      body: Index.enable_text(%{initiator: view.initiator && view.initiator.name}),
      label: dgettext("ui", "启用"),
      event: "confirm_enable",
      danger: false
    }

  defp confirm_spec(_, _view),
    do: %{title: "", body: "", label: "", event: "dismiss", danger: false}

  @impl true
  def render(assigns) do
    view = assigns.autopilot

    assigns =
      assign(assigns,
        a: view,
        perms: view.permissions,
        slug: assigns.current_scope.workspace.slug,
        items: more_items(view),
        spec: confirm_spec(assigns.confirm, view)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@a.name}>
          <:crumb navigate={"/w/#{@slug}/autopilots"}>{dgettext("ui", "自动化")}</:crumb>
          <:actions>
            <.badge :if={@a.enabled} tone={:success} id="autopilot-state" data-state="enabled">
              {dgettext("ui", "已启用")}
            </.badge>
            <.badge :if={!@a.enabled} id="autopilot-state" data-state="disabled">
              {dgettext("ui", "已停用")}
            </.badge>
            <.button
              :if={@perms.manage}
              id="autopilot-edit"
              size="sm"
              icon="lucide-pencil"
              patch={Url.put_params(@uri || "", %{panel: "edit"})}
            >
              {dgettext("ui", "编辑")}
            </.button>
            <.button
              :if={@perms.run}
              id="autopilot-run-now"
              variant="primary"
              size="sm"
              icon="lucide-play"
              patch={Url.put_params(@uri || "", %{panel: "run-now"})}
            >
              {dgettext("ui", "立即运行")}
            </.button>
            <.dropdown
              :if={@items != []}
              id="autopilot-more"
              items={@items}
              label={dgettext("ui", "更多操作")}
              align={:end}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </:actions>
        </.page_header>
      </:header>

      <div class="flex flex-col gap-6 px-4 py-4 lg:px-6">
        <div
          :if={@run_result}
          id="run-now-result"
          role="status"
          data-kind={@run_result.kind}
          class="flex items-center gap-2 rounded-field border border-border bg-surface px-3 py-2 text-body text-fg"
        >
          <.icon name="lucide-info" class="size-4 shrink-0 text-fg-muted" />
          <span>{@run_result.text}</span>
          <.record_result_link record={@run_result} slug={@slug} />
          <span class="flex-1" />
          <.icon_button
            icon="lucide-x"
            label={dgettext("ui", "关闭")}
            size="xs"
            phx-click="dismiss_result"
          />
        </div>

        <div
          :if={!@a.enabled}
          id="autopilot-disabled-banner"
          role="status"
          class="flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <.icon name="lucide-circle-pause" class="size-4 shrink-0" />
          <span class="flex-1" data-reason>
            {disabled_text(@a.disabled_reason) || dgettext("ui", "已停用")}
          </span>
          <.button :if={@perms.manage} id="autopilot-banner-enable" size="xs" phx-click="enable">
            {dgettext("ui", "启用")}
          </.button>
        </div>

        <div
          :if={@a.warnings != []}
          id="autopilot-warnings"
          role="status"
          class="flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
          {dgettext("ui", "下一次触发会失败：%{reasons}",
            reasons: Enum.map_join(@a.warnings, "、", &warning_text/1)
          )}
        </div>

        <section id="autopilot-config" aria-label={dgettext("ui", "配置")}>
          <.property_list>
            <.property_row label={dgettext("ui", "目标")} data-config="agent">
              <.actor_chip actor={target_actor(@a.agent)} />
            </.property_row>
            <.property_row
              label={dgettext("ui", "模式")}
              value={mode_label(@a.mode)}
              data-config="mode"
            />
            <.property_row
              label={dgettext("ui", "项目")}
              value={@a.project && "#{@a.project.key} · #{@a.project.name}"}
              data-config="project"
            />
            <.property_row
              :if={to_string(@a.mode) == "create_task"}
              label={dgettext("ui", "标题模板")}
              value={@a.title_template}
              data-config="title-template"
            />
            <.property_row
              :if={to_string(@a.mode) == "run_only"}
              label={dgettext("ui", "允许建任务")}
              value={if(@a.create_tasks, do: dgettext("ui", "是"), else: dgettext("ui", "否"))}
              data-config="create-tasks"
            />
            <.property_row label={dgettext("ui", "计划")} data-config="schedule">
              <span class="flex min-w-0 flex-wrap items-center gap-x-2">
                <span>{trigger_text(@a)}</span>
                <code :if={@a.cron} class="font-mono text-label text-fg-muted">{@a.cron}</code>
              </span>
            </.property_row>
            <.property_row :if={@upcoming != []} label={dgettext("ui", "接下来 5 次")}>
              <ol id="autopilot-upcoming" class="flex flex-col py-1 font-mono text-label text-fg">
                <li :for={at <- @upcoming}>{local_time(at, @a.timezone, weekday: true)}</li>
              </ol>
            </.property_row>
            <.property_row
              label={dgettext("ui", "重叠策略")}
              value={overlap_label(@a.overlap)}
              data-config="overlap"
            />
            <.property_row label={dgettext("ui", "授权来源")} data-config="initiator">
              <span :if={@a.initiator}>
                {dgettext("ui", "以 %{name} 的权限运行", name: @a.initiator.name)}
              </span>
              <span :if={!@a.initiator} class="text-fg-muted">{dgettext("ui", "无（已离开）")}</span>
            </.property_row>
            <.property_row
              label={dgettext("ui", "创建者")}
              value={@a.created_by && @a.created_by.name}
              data-config="created-by"
            />
            <.property_row
              :if={(@a.consecutive_failures || 0) > 0}
              label={dgettext("ui", "连续失败")}
              value={dgettext("ui", "%{n} 次", n: @a.consecutive_failures)}
              data-config="failures"
            />
          </.property_list>
        </section>

        <section id="autopilot-instructions" class="flex flex-col gap-2">
          <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "说明")}</h2>
          <.markdown
            content={@a.instructions || ""}
            scope={@current_scope}
            anchor_ns={"autopilot-#{@a.id}"}
          />
        </section>

        <section id="autopilot-webhook" class="flex flex-col gap-2">
          <h2 class="text-label font-medium text-fg-muted">Webhook</h2>
          <div :if={!@a.webhook.enabled} class="flex flex-col gap-2">
            <p class="text-body text-fg-muted">
              {dgettext("ui", "外部系统可以用 POST 请求触发这个自动化。")}
            </p>
            <div :if={@perms.manage} class="flex items-center gap-2">
              <.button id="webhook-enable" size="sm" icon="lucide-webhook" phx-click="enable_webhook">
                {dgettext("ui", "开启 webhook")}
              </.button>
              <span class="text-caption text-fg-muted">
                {dgettext("ui", "开启后，定时与 webhook 触发改为以你的权限运行")}
              </span>
            </div>
          </div>
          <div :if={@a.webhook.enabled} class="flex flex-col gap-2">
            <.copy_command id="webhook-url" text={@a.webhook.url} />
            <div :if={@perms.manage} class="flex flex-wrap items-center gap-2">
              <.button id="webhook-rotate" size="sm" phx-click="ask_rotate">
                {dgettext("ui", "轮换令牌")}
              </.button>
              <.button id="webhook-disable" size="sm" variant="ghost" phx-click="ask_disable_webhook">
                {dgettext("ui", "关闭 webhook")}
              </.button>
              <span class="text-caption text-fg-muted">
                {dgettext("ui", "轮换后，定时与 webhook 触发改为以你的权限运行")}
              </span>
            </div>
          </div>
        </section>

        <section id="autopilot-history" class="flex flex-col gap-2">
          <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "触发历史")}</h2>
          <.data_table
            id="autopilot-records"
            rows={@streams.records}
            label={dgettext("ui", "触发历史")}
            row_click={&JS.patch(Url.put_params(@uri || "", %{record: &1.id}))}
            row_version={&{&1.status, &1[:reason], &1[:finished_at]}}
            has_more={@more?}
            load_more="load_more"
          >
            <:col :let={r} label={dgettext("ui", "时间")} class="w-28 md:w-36">
              <span class="font-mono text-label text-fg-muted" data-time>
                {local_time(r.inserted_at, @browser_tz, [])}
              </span>
            </:col>
            <:col :let={r} label={dgettext("ui", "来源")} class="w-32">
              <span class="truncate text-fg" data-source>{source_label(r)}</span>
            </:col>
            <:col :let={r} label={dgettext("ui", "状态")} class="w-24">
              <.record_badge status={r.status} />
            </:col>
            <:col :let={r} label={dgettext("ui", "原因")} secondary>
              <span class="truncate text-fg-muted" data-reason>{reason_text(r.reason)}</span>
            </:col>
            <:col :let={r} label={dgettext("ui", "结果")} secondary>
              <span class="truncate text-fg-muted" data-result>{first_line(r.result)}</span>
            </:col>
            <%!-- Secondary: below md the row opens the record panel with the same link
                 (the four fixed columns overflowed 390 px, walkthrough 5.1). --%>
            <:col :let={r} label={dgettext("ui", "任务 / 运行")} class="w-28" secondary>
              <span data-link><.record_result_link record={r} slug={@slug} /></span>
            </:col>
          </.data_table>
          <p
            :if={MapSet.size(@loaded) == 0}
            id="autopilot-history-empty"
            class="py-4 text-center text-body text-fg-muted"
          >
            {dgettext("ui", "还没有触发记录")}
          </p>
        </section>
      </div>

      <AutopilotForm.panel
        :if={@perms.manage}
        form={@autopilot_form}
        scope={@current_scope}
        close_path={Url.drop_params(@uri || "", ["panel"])}
      />

      <.side_panel
        :if={@perms.run}
        id="run-now-panel"
        show={@run_panel != nil}
        title={dgettext("ui", "立即运行 %{name}", name: @a.name)}
        dirty={@run_panel != nil and @run_panel.note != ""}
        patch_on_close={Url.drop_params(@uri || "", ["panel"])}
      >
        <div
          :if={!@a.enabled}
          id="run-now-trial"
          class="mb-4 flex items-start gap-2 rounded-field border border-border bg-surface px-3 py-2 text-body text-fg-muted"
        >
          <.icon name="lucide-flask-conical" class="mt-0.5 size-4 shrink-0" />
          {dgettext("ui", "这个自动化已停用：这是一次试运行，成功不会自动启用。")}
        </div>
        <.form
          :if={@run_panel}
          for={%{}}
          as={:run}
          id="run-now-form"
          phx-change="run_now_change"
          phx-submit="run_now_submit"
          class="flex flex-col gap-2"
        >
          <.input
            id="run-now-note"
            name="run[note]"
            type="textarea"
            label={dgettext("ui", "附加说明（可选）")}
            value={@run_panel.note}
            errors={if(@run_panel.error, do: [@run_panel.error], else: [])}
            rows="5"
            phx-debounce="300"
          />
          <p id="run-now-note-size" class="text-right text-caption text-fg-muted">
            {dgettext("ui", "%{bytes} / %{max} 字节", bytes: byte_size(@run_panel.note), max: 4096)}
          </p>
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="run-now-submit"
              type="submit"
              form="run-now-form"
              variant="primary"
              phx-disable-with={dgettext("ui", "正在提交…")}
            >
              {dgettext("ui", "立即运行")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <.side_panel
        id="record-panel"
        show={@record != nil}
        title={dgettext("ui", "触发记录")}
        patch_on_close={Url.drop_params(@uri || "", ["record"])}
      >
        <.record_details
          :if={@record}
          record={@record}
          slug={@slug}
          tz={@browser_tz}
          scope={@current_scope}
        />
      </.side_panel>

      <.confirm_dialog
        id="autopilot-confirm"
        show={@confirm != nil}
        title={@spec.title}
        danger={@spec.danger}
        confirm_label={@spec.label}
        on_confirm={@spec.event}
        on_cancel={JS.push("dismiss")}
      >
        {@spec.body}
      </.confirm_dialog>

      <.modal
        id="webhook-token-dialog"
        show={@token != nil}
        title={
          if(@token && @token.rotated?,
            do: dgettext("ui", "新的 webhook 令牌"),
            else: dgettext("ui", "webhook 已开启")
          )
        }
        on_cancel={JS.push("close_token")}
      >
        <div :if={@token} class="flex flex-col gap-4">
          <p :if={@token.rotated?} id="webhook-token-rotated" class="text-body text-fg">
            {dgettext("ui", "旧令牌已失效。")}
          </p>
          <div class="flex flex-col gap-1">
            <span class="text-label font-medium text-fg">{dgettext("ui", "地址")}</span>
            <.copy_command id="webhook-token-url" text={@token.url} />
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-label font-medium text-fg">{dgettext("ui", "令牌")}</span>
            <.secret_once id="webhook-token" value={@token.token} />
            <p class="text-caption text-fg-muted">{dgettext("ui", "丢失请轮换令牌。")}</p>
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-label font-medium text-fg">{dgettext("ui", "示例")}</span>
            <div class="flex items-start gap-2 rounded-field border border-border bg-surface px-2 py-1">
              <pre
                id="webhook-token-curl"
                class="min-w-0 flex-1 overflow-x-auto font-mono text-label text-fg"
              >{curl(@token.url, @token.token)}</pre>
              <.copy_button
                id="webhook-token-curl-copy"
                text={curl(@token.url, @token.token)}
                target="#webhook-token-curl"
              />
            </div>
            <p class="text-caption text-fg-muted">
              {dgettext("ui", "每次投递用不同的 X-Delivery-Id；重复的投递 ID 只触发一次。")}
            </p>
          </div>
        </div>
        <:footer :let={cancel}>
          <.button id="webhook-token-done" variant="primary" phx-click={cancel}>
            {dgettext("ui", "完成")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :record, :map, required: true
  attr :slug, :string, required: true
  attr :tz, :string, required: true
  attr :scope, :map, required: true

  defp record_details(assigns) do
    assigns = assign(assigns, :payload, payload_view(assigns.record[:payload]))

    ~H"""
    <div id={"record-details-#{@record.id}"} class="flex flex-col gap-4">
      <.property_list>
        <.property_row label={dgettext("ui", "状态")}>
          <.record_badge status={@record.status} />
        </.property_row>
        <.property_row
          :if={@record.reason}
          label={dgettext("ui", "原因")}
          value={reason_text(@record.reason)}
          data-detail="reason"
        />
        <.property_row
          label={dgettext("ui", "来源")}
          value={source_label(@record)}
          data-detail="source"
        />
        <.property_row
          :if={@record[:scheduled_for]}
          label={dgettext("ui", "计划时刻")}
          value={local_time(@record.scheduled_for, @tz, [])}
        />
        <.property_row
          :if={@record[:started_at]}
          label={dgettext("ui", "开始")}
          value={local_time(@record.started_at, @tz, [])}
        />
        <.property_row
          :if={@record[:finished_at]}
          label={dgettext("ui", "结束")}
          value={local_time(@record.finished_at, @tz, [])}
        />
        <.property_row :if={@record[:task] || @record[:run_id]} label={dgettext("ui", "任务 / 运行")}>
          <span data-detail="link"><.record_result_link record={@record} slug={@slug} /></span>
        </.property_row>
      </.property_list>

      <section :if={@record[:note]} id="record-note" class="flex flex-col gap-1">
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "手动附加的说明")}</h3>
        <p class="whitespace-pre-wrap text-body text-fg">{@record.note}</p>
      </section>

      <section :if={@record[:result]} id="record-result" class="flex flex-col gap-1">
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "结果")}</h3>
        <.markdown content={@record.result} scope={@scope} anchor_ns={"record-#{@record.id}"} />
      </section>

      <section :if={@payload} id="record-payload" class="flex flex-col gap-1">
        <h3 class="text-label font-medium text-warning-fg">
          {dgettext("ui", "Webhook 内容（来自外部，不可信）")}
        </h3>
        <pre
          :if={elem(@payload, 0) == :json}
          id="record-payload-json"
          class="overflow-x-auto rounded-field border border-border bg-surface p-2 font-mono text-label text-fg"
        >{elem(@payload, 1)}</pre>
        <div :if={elem(@payload, 0) == :raw} id="record-payload-raw" class="flex flex-col gap-1">
          <p class="text-caption text-fg-muted">
            {if(elem(@payload, 2),
              do: dgettext("ui", "不是 JSON，按文本显示（已截断）"),
              else: dgettext("ui", "不是 JSON，按文本显示")
            )}
          </p>
          <pre class="overflow-x-auto whitespace-pre-wrap rounded-field border border-border bg-surface p-2 font-mono text-label text-fg">{elem(@payload, 1)}</pre>
        </div>
      </section>
    </div>
    """
  end
end

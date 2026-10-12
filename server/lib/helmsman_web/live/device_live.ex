defmodule HelmsmanWeb.DeviceLive do
  @moduledoc """
  `/device` (spec web-runtimes 设备码确认页, design D6): a logged-in user confirms the
  `helmsman login` of a daemon. Steps `:enter` → `:confirm` → `:approved` / `:denied`
  in one LiveView; `?code=` looks the code up once the socket is connected (every
  look-up counts towards the domain's per-user rate limit).
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.{Daemons, Workspaces}

  @selectable [:owner, :admin, :member]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("ui", "授权设备"),
       step: :enter,
       code: "",
       error: nil,
       device: nil,
       workspaces: [],
       selected: MapSet.new(),
       rejected: MapSet.new(),
       approved: []
     )}
  end

  @impl true
  def handle_params(%{"code" => code}, _uri, %{assigns: %{step: :enter}} = socket)
      when is_binary(code) and code != "" do
    socket = assign(socket, :code, code)
    {:noreply, if(connected?(socket), do: look_up(socket, code), else: socket)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("look_up", %{"code" => code}, %{assigns: %{step: :enter}} = socket),
    do: {:noreply, socket |> assign(:code, code) |> look_up(code)}

  def handle_event("select", params, %{assigns: %{step: :confirm}} = socket) do
    selectable = selectable_ids(socket.assigns.workspaces)

    selected =
      params
      |> Map.get("workspace_ids", [])
      |> List.wrap()
      |> Enum.flat_map(&parse_id/1)
      |> Enum.filter(&MapSet.member?(selectable, &1))

    {:noreply, assign(socket, :selected, MapSet.new(selected))}
  end

  def handle_event("approve", params, %{assigns: %{step: :confirm}} = socket) do
    {:noreply, socket} = handle_event("select", params, socket)
    ids = socket.assigns.selected |> MapSet.to_list() |> Enum.sort()

    if ids == [] do
      {:noreply, socket}
    else
      approve(socket, ids)
    end
  end

  def handle_event("deny", _params, %{assigns: %{step: :confirm}} = socket) do
    case Daemons.deny_device(socket.assigns.current_scope, socket.assigns.device.user_code) do
      {:ok, _} -> {:noreply, assign(socket, step: :denied, error: nil)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp approve(socket, ids) do
    scope = socket.assigns.current_scope

    case Daemons.approve_device(scope, socket.assigns.device.user_code, ids) do
      {:ok, _} ->
        approved = Enum.filter(socket.assigns.workspaces, &(&1.workspace.id in ids))
        {:noreply, assign(socket, step: :approved, approved: approved, error: nil)}

      {:error, {:invalid_workspaces, invalid}} ->
        invalid = MapSet.new(invalid)
        # The roles changed meanwhile: reload them, keep the other choices.
        workspaces = list_workspaces(scope)

        {:noreply,
         assign(socket,
           workspaces: workspaces,
           rejected: invalid,
           selected:
             socket.assigns.selected
             |> MapSet.difference(invalid)
             |> MapSet.intersection(selectable_ids(workspaces)),
           error: dgettext("ui", "你在标出的工作区里已不能运行 Agent，请取消勾选后重试")
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  defp look_up(socket, code) do
    scope = socket.assigns.current_scope

    case Daemons.get_device_auth(scope, String.trim(code)) do
      {:ok, device} ->
        workspaces = list_workspaces(scope)
        selectable = selectable_ids(workspaces)

        assign(socket,
          step: :confirm,
          error: nil,
          device: device,
          workspaces: workspaces,
          rejected: MapSet.new(),
          selected: if(MapSet.size(selectable) == 1, do: selectable, else: MapSet.new())
        )

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp failed(socket, {:rate_limited, _}),
    do: assign(socket, :error, dgettext("ui", "尝试过于频繁，请 1 分钟后再试"))

  defp failed(socket, _not_found),
    do: assign(socket, step: :enter, device: nil, error: invalid_message())

  defp invalid_message,
    do: dgettext("ui", "设备码无效或已过期，请在终端重新执行 helmsman login")

  defp list_workspaces(scope),
    do: Workspaces.list_for_user(scope.user)

  defp selectable_ids(workspaces),
    do:
      for(
        %{role: role, workspace: w} <- workspaces,
        role in @selectable,
        into: MapSet.new(),
        do: w.id
      )

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> [id]
      _ -> []
    end
  end

  defp machine(device, key) do
    machine = device.machine || %{}
    Map.get(machine, Atom.to_string(key)) || Map.get(machine, key)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={dgettext("ui", "授权设备")}>
      <div :if={@step == :enter} id="device-enter">
        <p class="mb-4 text-body text-fg-muted">
          {dgettext("ui", "输入终端里 helmsman login 显示的设备码。")}
        </p>
        <.form for={%{}} id="device-code-form" phx-submit="look_up" class="flex flex-col gap-4">
          <.input
            id="device-code"
            name="code"
            label={dgettext("ui", "设备码")}
            value={@code}
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            errors={if(@error, do: [@error], else: [])}
          />
          <.button id="device-continue" type="submit" variant="primary">
            {dgettext("ui", "继续")}
          </.button>
        </.form>
      </div>

      <div :if={@step == :confirm} id="device-confirm" class="flex flex-col gap-4">
        <div id="device-machine" class="rounded-field border border-border bg-raised p-3">
          <div class="flex items-center gap-2 text-body font-medium text-fg">
            <.icon name="lucide-laptop" class="size-4 text-fg-muted" />
            <span data-machine-name>{machine(@device, :name)}</span>
          </div>
          <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-caption text-fg-muted">
            <dt>{dgettext("ui", "系统")}</dt>
            <dd data-machine-os>{machine(@device, :os)} / {machine(@device, :arch)}</dd>
            <dt>{dgettext("ui", "版本")}</dt>
            <dd data-machine-version>{machine(@device, :daemon_version)}</dd>
            <dt>{dgettext("ui", "有效期")}</dt>
            <dd id="device-expires">
              <time
                id="device-expires-at"
                datetime={DateTime.to_iso8601(@device.expires_at)}
                phx-hook=".ClockTime"
              >
                {Calendar.strftime(@device.expires_at, "%H:%M UTC")}
              </time>
              {dgettext("ui", "前有效")}
            </dd>
          </dl>
        </div>
        <p
          role="note"
          class="flex gap-2 rounded-field border border-warning tint-warning p-3 text-body text-warning-fg"
        >
          <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
          {dgettext(
            "ui",
            "只有当你自己刚在这台机器上运行了 helmsman login 时才授权：授权后，这台机器可以在所选工作区里以你的身份执行 Agent"
          )}
        </p>
        <p :if={@error} id="device-error" role="alert" class="text-body text-danger-fg">{@error}</p>
        <.form
          for={%{}}
          id="device-approve-form"
          phx-change="select"
          phx-submit="approve"
          class="flex flex-col gap-4"
        >
          <fieldset class="flex flex-col gap-1">
            <legend class="mb-1 text-body font-medium text-fg">
              {dgettext("ui", "在这些工作区运行 Agent")}
            </legend>
            <input type="hidden" name="workspace_ids[]" value="" />
            <label
              :for={%{workspace: w, role: role} <- @workspaces}
              id={"device-workspace-#{w.id}"}
              class={[
                "flex items-start gap-2 rounded-field px-2 py-1.5",
                MapSet.member?(@rejected, w.id) && "border border-danger tint-danger",
                role not in [:owner, :admin, :member] && "opacity-60"
              ]}
              data-rejected={MapSet.member?(@rejected, w.id)}
            >
              <input
                type="checkbox"
                name="workspace_ids[]"
                value={w.id}
                checked={MapSet.member?(@selected, w.id)}
                disabled={role not in [:owner, :admin, :member]}
                class="mt-0.5 size-4 accent-brand"
              />
              <span class="flex min-w-0 flex-col">
                <span class="truncate text-body text-fg">{w.name}</span>
                <span
                  :if={role not in [:owner, :admin, :member]}
                  class="text-caption text-fg-muted"
                >
                  {dgettext("ui", "viewer 不能运行 Agent")}
                </span>
                <span :if={MapSet.member?(@rejected, w.id)} class="text-caption text-danger-fg">
                  {dgettext("ui", "你在这个工作区已不能运行 Agent")}
                </span>
              </span>
            </label>
          </fieldset>
          <div class="flex items-center justify-end gap-2">
            <.button id="device-deny" phx-click="deny">{dgettext("ui", "拒绝")}</.button>
            <.button
              id="device-approve"
              type="submit"
              variant="primary"
              disabled={MapSet.size(@selected) == 0}
            >
              {dgettext("ui", "授权")}
            </.button>
          </div>
        </.form>
      </div>

      <div :if={@step == :approved} id="device-approved" class="flex flex-col gap-3">
        <p class="flex items-center gap-2 text-body text-fg">
          <.icon name="lucide-circle-check" class="size-4 text-success-fg" />
          {dgettext("ui", "已授权 %{machine}，回到终端即可，守护进程会自动完成登录", machine: machine(@device, :name))}
        </p>
        <ul class="flex flex-col gap-1">
          <li :for={%{workspace: w} <- @approved}>
            <.link
              id={"device-runtimes-#{w.slug}"}
              navigate={"/w/#{w.slug}/settings/runtimes"}
              class="text-body text-brand-fg hover:underline"
            >
              {dgettext("ui", "%{workspace} 的运行时", workspace: w.name)}
            </.link>
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClockTime">
        const pad = n => String(n).padStart(2, "0")
        export default {
          mounted() { this.render() },
          updated() { this.render() },
          render() {
            const at = new Date(this.el.getAttribute("datetime"))
            if (!isNaN(at)) this.el.textContent = `${pad(at.getHours())}:${pad(at.getMinutes())}`
          }
        }
      </script>

      <p :if={@step == :denied} id="device-denied" class="text-body text-fg">
        {dgettext("ui", "已拒绝这次登录")}
      </p>
    </Layouts.auth>
    """
  end
end

defmodule HelmsmanWeb.AvatarEditor do
  @moduledoc """
  The avatar of an identity with its change / remove entry (add-actor-avatars D10, D11;
  update-actor-icons D12; web-avatars 头像编辑对话框 … 移除头像, 选择内置图标).

  Attributes: `scope`, `target` (`:me | {:actor, name}`), `actor` (the map of
  `actor_mark/1`, already decorated), `rights` (`HelmsmanWeb.AvatarData.can_manage?/2`:
  `:set | :remove_only | false`) and `size` (`:lg | :xl`).

  * `rights == :set`: the mark is a 「更换头像」 menu button with 「上传图片…」,
    「选择图标…」 and, with a custom avatar (an image or a built-in icon), 「恢复缺省头像」;
    `:remove_only` (admin and above facing someone else's Agent or squad) shows only
    「恢复缺省头像」 and only when there is a custom avatar; otherwise the plain mark,
    neither clickable nor focusable.
  * The dialog (server-controlled, `@open`) has the tabs 「上传图片」 and 「内置图标」
    (`@avatar_tab`, opened on the menu item's tab) and, under both, the default mark the
    identity falls back to (「缺省头像」).
  * The image tab hosts the `AvatarCropper` hook, which encodes the crop and hands it to
    the hidden live upload `:avatar` (outside the dialog, in the component root) named
    `avatar-<nonce>.<ext>`. Saving is the upload's completion (`handle_progress/3`,
    `entry.done?`), never a separate event: `Avatars.put/3` runs at most once per entry,
    and only when the entry's nonce is the dialog's current one while the dialog is open
    on the image tab. Opening, closing, choosing another image and switching tabs cancel
    the entries and renew the nonce, so a stale upload that still completes is consumed
    and dropped (the hook also abandons a save still encoding, D12).
  * The icon tab lists the built-in icons (`HelmsmanWeb.Brands.icon_groups/0`) as one
    group of native radio buttons with a search; saving calls `Avatars.put_icon/3`.
  * Errors (upload, domain and client side) show at the top of the dialog, which stays
    open; the hook gets `hm:avatar-done` to re-enable its controls.
  * Notices go to the page as `{:put_flash, kind, message}` (handled by
    `HelmsmanWeb.Shell` on workspace pages).
  """
  use HelmsmanWeb, :live_component

  alias HelmsmanWeb.{Appearance, AvatarData, Brands}

  @client_errors %{
    "invalid_image" => :invalid_image,
    "too_complex" => :too_complex,
    "source_too_large" => :source_too_large
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(open: false, ready: false, error: nil, confirm: false, nonce: nonce())
     |> assign(avatar_tab: :image, query: "", selected: nil)
     |> allow_upload(:avatar,
       accept: ~w(.png .jpg .jpeg .webp),
       max_entries: 1,
       max_file_size: 262_144,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :scope, :target, :actor, :rights]))
     |> assign(:size, Map.get(assigns, :size, :lg))}
  end

  @impl true
  def handle_event("open", params, socket) do
    tab = if params["tab"] == "icon", do: :icon, else: :image

    if socket.assigns.rights == :set,
      do: {:noreply, socket |> reset() |> assign(open: true) |> show_tab(tab)},
      else: {:noreply, socket}
  end

  # Leaving the image tab is closing it: earlier uploads, and a save still encoding in
  # the hook (the nonce changes), must not land.
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["image", "icon"] do
    tab = String.to_existing_atom(tab)

    if socket.assigns.open and tab != socket.assigns.avatar_tab,
      do: {:noreply, show_tab(socket, tab)},
      else: {:noreply, socket}
  end

  def handle_event("icons", params, socket) do
    query = params |> Map.get("q", socket.assigns.query) |> to_string()
    selected = if is_binary(params["icon"]), do: params["icon"], else: socket.assigns.selected
    {:noreply, assign(socket, query: query, selected: selected)}
  end

  def handle_event("save_icon", params, socket) do
    icon = if is_binary(params["icon"]), do: params["icon"], else: socket.assigns.selected

    if socket.assigns.open and is_binary(icon) and icon != current_icon(socket.assigns.actor) do
      case AvatarData.put_icon(socket.assigns.scope, socket.assigns.target, icon) do
        {:ok, _} -> {:noreply, socket |> reset() |> flash(:info, dgettext("ui", "头像已更新"))}
        {:error, code} -> {:noreply, assign(socket, error: AvatarData.error_message(code))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, reset(socket)}

  # The hook decoded another image: earlier uploads must not land.
  def handle_event("source", _params, socket) do
    {:noreply, socket |> cancel_entries() |> assign(nonce: nonce(), ready: true, error: nil)}
  end

  def handle_event("client_error", %{"code" => code}, socket) do
    error = Map.get(@client_errors, code, :invalid_image)
    {:noreply, assign(socket, :error, AvatarData.error_message(error))}
  end

  def handle_event("validate", _params, socket) do
    case upload_error(socket.assigns.uploads.avatar) do
      nil ->
        {:noreply, socket}

      message ->
        socket = cancel_entries(socket)

        {:noreply,
         socket
         |> assign(:error, message)
         |> push_event("hm:avatar-done", %{id: "#{socket.assigns.id}-cropper"})}
    end
  end

  def handle_event("ask_remove", _params, socket),
    do: {:noreply, assign(socket, :confirm, socket.assigns.rights in [:set, :remove_only])}

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :confirm, false)}

  def handle_event("remove", _params, socket) do
    socket = assign(socket, :confirm, false)

    case AvatarData.delete(socket.assigns.scope, socket.assigns.target) do
      :ok ->
        {:noreply, flash(socket, :info, dgettext("ui", "已恢复缺省头像"))}

      {:error, code} ->
        {:noreply, flash(socket, :error, AvatarData.error_message(code))}
    end
  end

  @doc false
  def handle_progress(:avatar, %{done?: false}, socket), do: {:noreply, socket}

  def handle_progress(:avatar, entry, socket) do
    current? =
      socket.assigns.open and socket.assigns.avatar_tab == :image and
        nonce_of(entry.client_name) == socket.assigns.nonce

    binary =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, if(current?, do: File.read!(path))}
      end)

    if current?, do: {:noreply, save(socket, binary)}, else: {:noreply, socket}
  end

  defp save(socket, binary) do
    case AvatarData.put(socket.assigns.scope, socket.assigns.target, binary) do
      {:ok, _} ->
        socket
        |> reset()
        |> flash(:info, dgettext("ui", "头像已更新"))

      {:error, code} ->
        fail(socket, code)
    end
  end

  # A component's own flash only reaches the page on a redirect: ask the page (the shell
  # for workspace pages) to show it.
  defp flash(socket, kind, message) do
    send(self(), {:put_flash, kind, message})
    socket
  end

  defp fail(socket, code) do
    socket
    |> assign(:error, AvatarData.error_message(code))
    |> push_event("hm:avatar-done", %{id: "#{socket.assigns.id}-cropper"})
  end

  defp reset(socket) do
    socket
    |> cancel_entries()
    |> assign(open: false, ready: false, error: nil, nonce: nonce())
  end

  # The crop stays in the hook (the panel is only hidden), hence `ready` is kept.
  defp show_tab(socket, tab) do
    socket
    |> cancel_entries()
    |> assign(
      avatar_tab: tab,
      nonce: nonce(),
      error: nil,
      query: "",
      selected: current_icon(socket.assigns.actor)
    )
  end

  defp current_icon(actor) do
    case Appearance.mark(actor) do
      {:icon, icon} -> icon
      _ -> nil
    end
  end

  # Consumed entries (done) have no upload process left to cancel.
  defp cancel_entries(socket) do
    for entry <- socket.assigns.uploads.avatar.entries, !entry.done?, reduce: socket do
      socket -> cancel_upload(socket, :avatar, entry.ref)
    end
  end

  defp upload_error(upload) do
    case upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1)) do
      [] -> nil
      [code | _] -> AvatarData.error_message(code)
    end
  end

  defp nonce, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp nonce_of("avatar-" <> rest), do: rest |> String.split(".") |> hd()
  defp nonce_of(_name), do: nil

  @impl true
  def render(assigns) do
    custom? = Appearance.custom?(assigns.actor)
    rights = assigns.rights

    items =
      if(rights == :set,
        do: [
          %{
            id: "#{assigns.id}-upload-item",
            label: dgettext("ui", "上传图片…"),
            icon: "lucide-image-up",
            on_select: JS.push("open", value: %{tab: "image"}, target: assigns.myself)
          },
          %{
            id: "#{assigns.id}-icon-item",
            label: dgettext("ui", "选择图标…"),
            icon: "lucide-shapes",
            on_select: JS.push("open", value: %{tab: "icon"}, target: assigns.myself)
          }
        ],
        else: []
      ) ++
        if(custom? and rights in [:set, :remove_only],
          do: [
            %{
              id: "#{assigns.id}-remove-item",
              label: dgettext("ui", "恢复缺省头像"),
              icon: "lucide-rotate-ccw",
              danger: true,
              on_select: JS.push("ask_remove", target: assigns.myself)
            }
          ],
          else: []
        )

    upload = assigns.uploads.avatar
    kind = kind(assigns.actor)
    default = assigns.actor |> Map.drop([:avatar_url, :avatar_icon]) |> Map.put(:kind, kind)
    current = current_icon(assigns.actor)

    assigns =
      assign(assigns,
        items: items,
        human?: kind == :human,
        busy: Enum.any?(upload.entries, &(&1.valid? and not &1.done?)),
        message: assigns.error || upload_error(upload),
        default: default,
        default_text: default_text(kind, default),
        groups: icon_groups(assigns.query),
        preview: default |> Map.put(:avatar_icon, assigns.selected),
        icon_changed?: is_binary(assigns.selected) and assigns.selected != current
      )

    ~H"""
    <div id={@id} class="inline-flex">
      <form id={"#{@id}-upload"} phx-change="validate" phx-target={@myself} class="hidden">
        <.live_file_input upload={@uploads.avatar} tabindex="-1" aria-hidden="true" />
      </form>
      <.dropdown
        :if={@items != []}
        id={"#{@id}-menu"}
        items={@items}
        label={dgettext("ui", "更换头像")}
        trigger_class={[
          "group relative h-auto p-0 hover:bg-transparent",
          if(@human?, do: "!rounded-full", else: "!rounded-[25%]")
        ]}
      >
        <:trigger>
          <.actor_mark actor={@actor} size={@size} />
          <span
            aria-hidden="true"
            class={[
              "absolute inset-0 hidden items-center justify-center bg-surface/70 text-fg",
              "group-hover:flex group-focus-visible:flex",
              if(@human?, do: "rounded-full", else: "rounded-[25%]")
            ]}
          >
            <.icon name="lucide-camera" class="size-5" />
          </span>
        </:trigger>
      </.dropdown>
      <.actor_mark :if={@items == []} actor={@actor} size={@size} />

      <%!-- No :if on the layers: removing the portal itself would skip their phx-remove,
      which restores the page underneath (inert). --%>
      <.modal
        :let={cancel}
        id={"#{@id}-dialog"}
        show={@open}
        size={:sm}
        title={dgettext("ui", "更换头像")}
        on_cancel={JS.push("close", target: @myself)}
      >
        <div class="flex flex-col gap-4">
          <div
            role="tablist"
            aria-label={dgettext("ui", "头像来源")}
            class="flex items-center gap-4 border-b border-border"
          >
            <button
              :for={
                {tab, label} <- [
                  image: dgettext("ui", "上传图片"),
                  icon: dgettext("ui", "内置图标")
                ]
              }
              type="button"
              id={"#{@id}-tab-#{tab}"}
              role="tab"
              aria-selected={to_string(@avatar_tab == tab)}
              aria-controls={"#{@id}-panel-#{tab}"}
              phx-click="tab"
              phx-value-tab={tab}
              phx-target={@myself}
              class={[
                "-mb-px inline-flex h-9 items-center border-b-2 text-body",
                if(@avatar_tab == tab,
                  do: "border-brand font-medium text-fg",
                  else: "border-transparent text-fg-muted hover:text-fg"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <div
            :if={@message}
            id={"#{@id}-error"}
            role="alert"
            class="flex items-start gap-2 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
          >
            <.icon name="lucide-circle-alert" class="mt-0.5 size-4 shrink-0" />
            <span>{@message}</span>
          </div>
          <div
            id={"#{@id}-panel-image"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-image"}
            hidden={@avatar_tab != :image}
          >
            <div
              id={"#{@id}-cropper"}
              phx-hook="AvatarCropper"
              phx-target={@myself}
              data-nonce={@nonce}
              data-upload-form={"#{@id}-upload"}
              class="flex flex-col gap-4"
            >
              <div id={"#{@id}-crop"} phx-update="ignore" class="flex flex-col items-center gap-3">
                <input
                  type="file"
                  data-crop-source
                  accept="image/png,image/jpeg,image/webp,image/gif,image/bmp"
                  class="hidden"
                  tabindex="-1"
                  aria-hidden="true"
                />
                <div
                  data-crop-drop
                  class="relative size-64 max-w-full overflow-hidden rounded-field border border-dashed border-border-strong bg-canvas data-[dragging]:border-brand"
                >
                  <canvas
                    data-crop-view
                    tabindex="0"
                    role="application"
                    aria-label={dgettext("ui", "裁剪区")}
                    aria-describedby={"#{@id}-crop-help"}
                    aria-roledescription={dgettext("ui", "头像裁剪")}
                    class="size-full cursor-move touch-none"
                  />
                  <span
                    aria-hidden="true"
                    class={[
                      "pointer-events-none absolute inset-0 shadow-[0_0_0_1px_var(--color-border-strong)]",
                      if(@human?, do: "rounded-full", else: "rounded-[25%]")
                    ]}
                  />
                </div>
                <p id={"#{@id}-crop-help"} class="text-center text-caption text-fg-muted">
                  {dgettext(
                    "ui",
                    "拖动或用方向键移动图片（按住 Shift 移动更多），+ / - 缩放，0 复位。也可以把图片拖到这里。"
                  )}
                </p>
                <label class="flex w-64 max-w-full items-center gap-2 text-label text-fg-muted">
                  <.icon name="lucide-zoom-out" class="size-4" />
                  <input
                    type="range"
                    data-crop-zoom
                    min="1"
                    max="4"
                    step="0.01"
                    value="1"
                    aria-label={dgettext("ui", "缩放")}
                    class="flex-1 accent-brand"
                  />
                  <.icon name="lucide-zoom-in" class="size-4" />
                </label>
                <div class="flex items-center gap-3 text-caption text-fg-muted">
                  <span>{dgettext("ui", "预览")}</span>
                  <canvas
                    data-crop-preview
                    data-size="40"
                    aria-hidden="true"
                    class={[
                      "size-10 bg-canvas",
                      if(@human?, do: "rounded-full", else: "rounded-[25%]")
                    ]}
                  />
                  <canvas
                    data-crop-preview
                    data-size="20"
                    aria-hidden="true"
                    class={[
                      "size-5 bg-canvas",
                      if(@human?, do: "rounded-full", else: "rounded-[25%]")
                    ]}
                  />
                </div>
                <.button size="sm" icon="lucide-image" data-crop-choose>
                  {dgettext("ui", "选择图片…")}
                </.button>
              </div>
              <div class="flex items-center justify-end gap-2">
                <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
                <.button
                  id={"#{@id}-save"}
                  variant="primary"
                  data-crop-save
                  disabled={!@ready or @busy}
                  aria-busy={@busy && "true"}
                >
                  {dgettext("ui", "保存")}
                </.button>
              </div>
            </div>
          </div>
          <div
            id={"#{@id}-panel-icon"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-icon"}
            hidden={@avatar_tab != :icon}
          >
            <form
              id={"#{@id}-icons"}
              phx-change="icons"
              phx-submit="save_icon"
              phx-target={@myself}
              class="flex flex-col gap-3"
            >
              <div class="relative">
                <.icon
                  name="lucide-search"
                  class="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-fg-subtle"
                />
                <input
                  id={"#{@id}-icon-search"}
                  type="search"
                  name="q"
                  value={@query}
                  phx-debounce="150"
                  autocomplete="off"
                  aria-label={dgettext("ui", "搜索图标")}
                  placeholder={dgettext("ui", "搜索图标")}
                  class="h-8 w-full rounded-field border border-border bg-surface pr-2 pl-8 text-body text-fg placeholder:text-fg-subtle focus:border-brand focus:outline-none"
                />
              </div>
              <div class="flex max-h-72 flex-col gap-3 overflow-y-auto pr-1">
                <fieldset
                  :for={{group, items} <- @groups}
                  id={"#{@id}-icons-#{group}"}
                  class="flex flex-col gap-1.5"
                >
                  <legend class="mb-1.5 text-label font-medium text-fg-muted">
                    {group_label(group)}
                  </legend>
                  <div class="grid grid-cols-4 gap-1.5 sm:grid-cols-5">
                    <label
                      :for={item <- items}
                      id={"#{@id}-icon-#{item.icon}"}
                      data-icon={item.icon}
                      class={[
                        "flex cursor-pointer flex-col items-center gap-1 rounded-field border px-1 py-2 text-center text-caption text-fg",
                        "hover:bg-hover has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-brand",
                        if(item.icon == @selected,
                          do: "border-brand bg-hover",
                          else: "border-transparent"
                        )
                      ]}
                    >
                      <input
                        type="radio"
                        name="icon"
                        value={item.icon}
                        checked={item.icon == @selected}
                        class="sr-only"
                      />
                      <.actor_mark
                        actor={Map.put(@default, :avatar_icon, item.icon)}
                        size={:md}
                      />
                      <span class="line-clamp-2 w-full">{item.name}</span>
                    </label>
                  </div>
                </fieldset>
                <p
                  :if={@groups == []}
                  id={"#{@id}-icons-empty"}
                  class="py-6 text-center text-body text-fg-muted"
                >
                  {dgettext("ui", "没有匹配的图标")}
                </p>
              </div>
              <div class="flex items-center gap-3 text-caption text-fg-muted">
                <span>{dgettext("ui", "预览")}</span>
                <span id={"#{@id}-icon-preview"} class="flex items-center gap-3">
                  <.actor_mark actor={@preview} size={:lg} />
                  <.actor_mark actor={@preview} size={:sm} />
                </span>
              </div>
              <div class="flex items-center justify-end gap-2">
                <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
                <.button
                  id={"#{@id}-icon-save"}
                  type="submit"
                  variant="primary"
                  disabled={!@icon_changed?}
                >
                  {dgettext("ui", "保存")}
                </.button>
              </div>
            </form>
          </div>
          <p
            id={"#{@id}-default"}
            class="flex items-center gap-2 border-t border-border pt-3 text-caption text-fg-muted"
          >
            <span>{dgettext("ui", "缺省头像：")}</span>
            <.actor_mark actor={@default} size={:sm} />
            <span class="text-fg">{@default_text}</span>
          </p>
        </div>
      </.modal>

      <.confirm_dialog
        id={"#{@id}-remove"}
        show={@confirm}
        danger
        title={dgettext("ui", "恢复缺省头像？")}
        confirm_label={dgettext("ui", "恢复缺省")}
        on_confirm="remove"
        target={@myself}
        on_cancel={JS.push("cancel_remove", target: @myself)}
      >
        <span class="inline-flex flex-wrap items-center gap-1.5">
          {dgettext("ui", "恢复后显示缺省头像：")}
          <.actor_mark actor={@default} size={:sm} />
          <span id={"#{@id}-remove-default"}>{@default_text}</span>
        </span>
      </.confirm_dialog>
    </div>
    """
  end

  defp kind(actor) do
    case Map.get(actor, :kind) do
      kind when kind in [:agent, "agent"] -> :agent
      kind when kind in [:squad, "squad"] -> :squad
      _ -> :human
    end
  end

  # What 「恢复缺省头像」 leads to (D12 缺省说明), from the appearance table and the brands.
  defp default_text(:human, _actor), do: dgettext("ui", "首字母")
  defp default_text(:squad, _actor), do: dgettext("ui", "小队图标")

  defp default_text(:agent, actor) do
    cli = Brands.cli_name(Map.get(actor, :provider))

    case Appearance.mark(actor) do
      {:vendor, vendor} ->
        vendor_text(Brands.vendor_name(vendor), Map.get(actor, :vendor_source), cli)

      {:cli, _icon} ->
        dgettext("ui", "%{cli} 图标", cli: cli)

      _ ->
        dgettext("ui", "机器人图标")
    end
  end

  defp vendor_text(vendor, :account, _cli),
    do: dgettext("ui", "%{vendor}（来自绑定的供应商账号）", vendor: vendor)

  defp vendor_text(vendor, :runtime, cli) when is_binary(cli),
    do: dgettext("ui", "%{vendor}（来自运行时的 %{cli} 配置）", vendor: vendor, cli: cli)

  defp vendor_text(vendor, _source, _cli), do: vendor

  defp group_label(:cli), do: dgettext("ui", "CLI")
  defp group_label(:vendor), do: dgettext("ui", "模型厂商")
  defp group_label(:platform), do: dgettext("ui", "平台网关")

  defp icon_groups(query) do
    query = query |> String.trim() |> String.downcase()

    for {group, items} <- Brands.icon_groups(),
        items = Enum.filter(items, &matches?(&1, query)),
        items != [],
        do: {group, items}
  end

  defp matches?(_item, ""), do: true
  defp matches?(item, query), do: Enum.any?(item.terms, &String.contains?(&1, query))
end

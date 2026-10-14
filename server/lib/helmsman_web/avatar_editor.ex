defmodule HelmsmanWeb.AvatarEditor do
  @moduledoc """
  The avatar of an identity with its change / remove entry (add-actor-avatars D10, D11;
  web-avatars 头像编辑对话框 … 移除头像).

  Attributes: `scope`, `target` (`:me | {:actor, name}`), `actor` (the map of
  `actor_mark/1`, already decorated), `rights` (`HelmsmanWeb.AvatarData.can_manage?/2`:
  `:set | :remove_only | false`) and `size` (`:lg | :xl`).

  * `rights == :set`: the mark is a 「更换头像」 menu button with 「上传图片…」 and, with an
    avatar, 「移除头像」; `:remove_only` (admin and above facing someone else's Agent or
    squad) shows only 「移除头像」 and only when there is an avatar; otherwise the plain
    mark, neither clickable nor focusable.
  * The dialog (server-controlled, `@open`) hosts the `AvatarCropper` hook, which encodes
    the crop and hands it to the hidden live upload `:avatar` (outside the dialog, in the
    component root) named `avatar-<nonce>.<ext>`.
  * Saving is the upload's completion (`handle_progress/3`, `entry.done?`), never a
    separate event: `Avatars.put/3` runs at most once per entry, and only when the entry's
    nonce is the dialog's current one while the dialog is open. Opening, closing and
    choosing another image cancel the entries and renew the nonce, so a stale upload that
    still completes is consumed and dropped.
  * Errors (upload, domain and client side) show at the top of the dialog, which stays
    open; the hook gets `hm:avatar-done` to re-enable its controls.
  * Notices go to the page as `{:put_flash, kind, message}` (handled by
    `HelmsmanWeb.Shell` on workspace pages).
  """
  use HelmsmanWeb, :live_component

  alias HelmsmanWeb.AvatarData

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
  def handle_event("open", _params, socket) do
    if socket.assigns.rights == :set,
      do: {:noreply, socket |> reset() |> assign(open: true)},
      else: {:noreply, socket}
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
    current? = socket.assigns.open and nonce_of(entry.client_name) == socket.assigns.nonce

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
    avatar? = is_binary(assigns.actor[:avatar_url])
    rights = assigns.rights

    items =
      if(rights == :set,
        do: [
          %{
            id: "#{assigns.id}-upload-item",
            label: dgettext("ui", "上传图片…"),
            icon: "lucide-image-up",
            on_select: JS.push("open", target: assigns.myself)
          }
        ],
        else: []
      ) ++
        if(avatar? and rights in [:set, :remove_only],
          do: [
            %{
              id: "#{assigns.id}-remove-item",
              label: dgettext("ui", "移除头像"),
              icon: "lucide-trash",
              danger: true,
              on_select: JS.push("ask_remove", target: assigns.myself)
            }
          ],
          else: []
        )

    upload = assigns.uploads.avatar

    assigns =
      assign(assigns,
        items: items,
        human?: assigns.actor[:kind] in [:human, "human"],
        busy: Enum.any?(upload.entries, &(&1.valid? and not &1.done?)),
        message: assigns.error || upload_error(upload)
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
        <div
          id={"#{@id}-cropper"}
          phx-hook="AvatarCropper"
          phx-target={@myself}
          data-nonce={@nonce}
          data-upload-form={"#{@id}-upload"}
          class="flex flex-col gap-4"
        >
          <div
            :if={@error}
            id={"#{@id}-error"}
            role="alert"
            class="flex items-start gap-2 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
          >
            <.icon name="lucide-circle-alert" class="mt-0.5 size-4 shrink-0" />
            <span>{@error}</span>
          </div>
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
                class={["size-10 bg-canvas", if(@human?, do: "rounded-full", else: "rounded-[25%]")]}
              />
              <canvas
                data-crop-preview
                data-size="20"
                aria-hidden="true"
                class={["size-5 bg-canvas", if(@human?, do: "rounded-full", else: "rounded-[25%]")]}
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
      </.modal>

      <.confirm_dialog
        id={"#{@id}-remove"}
        show={@confirm}
        danger
        title={dgettext("ui", "移除头像？")}
        confirm_label={dgettext("ui", "移除")}
        on_confirm="remove"
        target={@myself}
        on_cancel={JS.push("cancel_remove", target: @myself)}
      >
        {dgettext("ui", "移除后恢复缺省头像。")}
      </.confirm_dialog>
    </div>
    """
  end
end

defmodule HelmsmanWeb.InvitationLive do
  @moduledoc """
  Invitation page `/invite/:token` (spec web-workspace-entry 邀请预览页 / 接受邀请,
  design D6). Anyone may preview a valid invitation; every invalid one (unknown,
  expired, revoked, accepted) renders the same 邀请无效或已过期 card. Logged-in users
  accept it here; visitors log in or register first and come back (design D4).

  The token is only kept in the socket; it never goes into a flash or a log line.
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.Invitations
  alias HelmsmanWeb.Roles

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, token: token, error: nil, page_title: dgettext("ui", "接受邀请"))

    case Invitations.preview(token) do
      {:ok, preview} -> {:ok, assign(socket, state: :preview, preview: preview)}
      {:error, _} -> {:ok, assign(socket, state: :invalid, preview: nil)}
    end
  end

  @impl true
  def handle_event("accept", _params, %{assigns: %{state: :preview}} = socket) do
    %{current_scope: %{user: user}, token: token} = socket.assigns

    case user && Invitations.accept(user, token) do
      nil ->
        {:noreply, socket}

      {:ok, %{workspace: workspace}} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "已加入 %{workspace}", workspace: workspace.name))
         |> redirect(to: "/w/#{workspace.slug}")}

      {:error, :invalid_invitation} ->
        {:noreply, assign(socket, state: :invalid, preview: nil, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  def handle_event("accept", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    user = assigns.current_scope && assigns.current_scope.user
    assigns = assign(assigns, :user, user)

    ~H"""
    <Layouts.auth flash={@flash}>
      <div :if={@state == :invalid} id="invitation" data-state="invalid" class="flex flex-col gap-4">
        <div class="flex items-start gap-2">
          <.icon name="lucide-link-2-off" class="mt-0.5 size-5 shrink-0 text-fg-muted" />
          <p class="text-title font-medium text-fg">{dgettext("ui", "邀请无效或已过期")}</p>
        </div>
        <.button href={~p"/"}>{dgettext("ui", "返回首页")}</.button>
      </div>

      <div :if={@state == :preview} id="invitation" data-state="preview" class="flex flex-col gap-4">
        <p id="invitation-summary" class="text-title font-medium text-fg">
          {dgettext("ui", "%{inviter} 邀请你以「%{role}」身份加入 %{workspace}",
            inviter: @preview.inviter_name,
            role: Roles.label(@preview.role),
            workspace: @preview.workspace_name
          )}
        </p>
        <p id="invitation-expires" class="text-body text-fg-muted">
          {dgettext("ui", "邀请将于 %{time} 过期",
            time: Calendar.strftime(@preview.expires_at, "%Y-%m-%d %H:%M UTC")
          )}
        </p>
        <p
          :if={@preview.email_bound?}
          id="invitation-email-bound"
          role="note"
          class="flex gap-2 rounded-field tint-info p-3 text-body text-fg"
        >
          <.icon name="lucide-mail" class="mt-0.5 size-4 shrink-0 text-info" />
          {dgettext("ui", "此邀请只能由受邀邮箱的账号接受")}
        </p>

        <div
          :if={@error}
          id="invitation-error"
          role="alert"
          class="flex flex-col gap-1 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
        >
          <span>{error_message(@error, @preview.workspace_name)}</span>
          <.link
            :if={@error == :already_member}
            id="invitation-enter"
            href={~p"/"}
            class="font-medium underline"
          >
            {dgettext("ui", "进入工作区")}
          </.link>
        </div>

        <div :if={@user} class="flex flex-col gap-3">
          <p id="invitation-account" class="text-body text-fg-muted">
            {dgettext("ui", "当前账号：%{email}", email: @user.email)}
          </p>
          <.button
            id="invitation-accept"
            variant="primary"
            phx-click="accept"
            phx-disable-with={dgettext("ui", "正在加入…")}
            class="w-full"
          >
            {dgettext("ui", "接受并加入")}
          </.button>
          <.button
            id="invitation-switch-account"
            variant={if(@error == :email_mismatch, do: "primary", else: "ghost")}
            href={~p"/users/log-out?#{[return_to: "/invite/#{@token}"]}"}
            method="delete"
            class="w-full"
          >
            {dgettext("ui", "换个账号")}
          </.button>
        </div>

        <div :if={!@user} class="flex flex-col gap-2">
          <.button id="invitation-log-in" variant="primary" href={~p"/users/log-in"} class="w-full">
            {dgettext("ui", "登录后接受")}
          </.button>
          <.button
            id="invitation-register"
            href={~p"/users/register?#{[invitation: @token]}"}
            class="w-full"
          >
            {dgettext("ui", "注册新账号")}
          </.button>
        </div>
      </div>
    </Layouts.auth>
    """
  end

  @doc "The message shown when accepting fails with `reason`."
  def error_message(:email_mismatch, _workspace),
    do: dgettext("ui", "此邀请属于另一个邮箱，请用受邀邮箱的账号登录")

  def error_message(:email_unconfirmed, _workspace), do: dgettext("ui", "请先确认邮箱后再接受邀请")

  def error_message(:already_member, workspace),
    do: dgettext("ui", "你已经是 %{workspace} 的成员", workspace: workspace)

  def error_message(_reason, _workspace), do: dgettext("ui", "加入失败，请稍后重试")
end

defmodule HelmsmanWeb.UserLive.Settings do
  use HelmsmanWeb, :live_view

  alias Helmsman.{Accounts, Events}
  alias HelmsmanWeb.{AvatarData, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.personal
      flash={@flash}
      current_scope={@current_scope}
      active={:account}
      avatar={@avatar}
      class="max-w-[400px]"
    >
      <.header>
        {dgettext("ui", "账号设置")}
        <:subtitle>{dgettext("ui", "管理头像、显示名、邮箱和密码")}</:subtitle>
      </.header>

      <section id="avatar-section" aria-labelledby="avatar-heading" class="flex items-center gap-4">
        <.live_component
          module={HelmsmanWeb.AvatarEditor}
          id="my-avatar"
          scope={@current_scope}
          target={:me}
          rights={:set}
          size={:xl}
          actor={Map.merge(@avatar, %{name: user_name(@current_scope.user), kind: :human})}
        />
        <div class="flex min-w-0 flex-col gap-0.5">
          <h2 id="avatar-heading" class="text-title font-semibold text-fg">
            {dgettext("ui", "头像")}
          </h2>
          <p class="text-body text-fg-muted">{dgettext("ui", "显示在你加入的所有工作区")}</p>
        </div>
      </section>

      <hr class="my-6 border-border" />

      <.form
        for={@display_name_form}
        id="display_name_form"
        phx-submit="update_display_name"
        phx-change="validate_display_name"
        class="flex flex-col gap-3"
      >
        <.input
          field={@display_name_form[:display_name]}
          type="text"
          label={dgettext("ui", "显示名")}
          maxlength="64"
          required
        />
        <.button type="submit" variant="primary" phx-disable-with={dgettext("ui", "正在保存…")}>
          {dgettext("ui", "保存显示名")}
        </.button>
      </.form>

      <hr class="my-6 border-border" />

      <div :if={!@sudo_mode?} id="reauthenticate_notice" class="text-body text-fg-muted">
        <p>
          {dgettext("ui", "修改邮箱或密码前，需要")}<.link
            navigate={~p"/users/log-in"}
            class="font-medium text-brand-fg underline"
            phx-no-format
          >{dgettext("ui", "重新登录")}</.link>
        </p>
      </div>

      <.form
        :if={@sudo_mode?}
        for={@email_form}
        id="email_form"
        phx-submit="update_email"
        phx-change="validate_email"
        class="flex flex-col gap-3"
      >
        <.input
          field={@email_form[:email]}
          type="email"
          label={dgettext("ui", "邮箱")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button type="submit" variant="primary" phx-disable-with={dgettext("ui", "正在提交…")}>
          {dgettext("ui", "修改邮箱")}
        </.button>
      </.form>

      <hr :if={@sudo_mode?} class="my-6 border-border" />

      <.form
        :if={@sudo_mode?}
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
        class="flex flex-col gap-3"
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={dgettext("ui", "新密码")}
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label={dgettext("ui", "确认新密码")}
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button type="submit" variant="primary" phx-disable-with={dgettext("ui", "正在保存…")}>
          {dgettext("ui", "保存密码")}
        </.button>
      </.form>
    </Layouts.personal>
    """
  end

  @impl true
  def mount(%{"token" => token} = params, session, socket) do
    # Only the email and password actions need sudo mode; the display name
    # does not, so sudo mode is checked per action instead of per page.
    case UserAuth.on_mount(:require_sudo_mode, params, session, socket) do
      {:cont, socket} ->
        socket =
          case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
            {:ok, _user} ->
              put_flash(socket, :info, dgettext("ui", "邮箱已修改。"))

            {:error, _} ->
              put_flash(socket, :error, dgettext("ui", "邮箱修改链接无效或已过期。"))
          end

        {:ok, push_navigate(socket, to: ~p"/users/settings")}

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    if connected?(socket), do: Events.subscribe(Events.topic(:user, user.id))
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, dgettext("ui", "账号设置"))
      |> assign(:current_email, user.email)
      |> assign(:sudo_mode?, Accounts.sudo_mode?(user))
      |> assign(:display_name_form, to_form(Accounts.change_user_display_name(user)))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:avatar, AvatarData.user_avatar(user))

    {:ok, socket}
  end

  defp user_name(user), do: user.display_name || user.email

  @impl true
  def handle_info({:user_avatar_changed}, socket) do
    avatar = AvatarData.user_avatar(socket.assigns.current_scope.user)
    {:noreply, assign(socket, :avatar, avatar)}
  end

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate_display_name", %{"user" => user_params}, socket) do
    display_name_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_display_name(user_params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, display_name_form: display_name_form)}
  end

  def handle_event("update_display_name", %{"user" => user_params}, socket) do
    case Accounts.update_user_display_name(socket.assigns.current_scope.user, user_params) do
      {:ok, user} ->
        scope = %{socket.assigns.current_scope | user: user}

        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> assign(:display_name_form, to_form(Accounts.change_user_display_name(user)))
         |> put_flash(:info, dgettext("ui", "显示名已更新。"))}

      {:error, changeset} ->
        {:noreply, assign(socket, display_name_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.sudo_mode?(user) && Accounts.change_user_email(user, user_params) do
      false ->
        {:noreply, require_reauthentication(socket)}

      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = dgettext("ui", "确认链接已发送到新邮箱。")
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.sudo_mode?(user) && Accounts.change_user_password(user, user_params) do
      false ->
        {:noreply, require_reauthentication(socket)}

      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # The page may have been opened while in sudo mode and submitted after it
  # expired: hide the sensitive forms and ask the user to log in again.
  defp require_reauthentication(socket) do
    socket
    |> assign(:sudo_mode?, false)
    |> put_flash(:error, dgettext("ui", "需要重新登录才能修改邮箱或密码。"))
  end
end

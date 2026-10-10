defmodule HelmsmanWeb.UserLive.Registration do
  use HelmsmanWeb, :live_view

  alias Helmsman.Accounts
  alias Helmsman.Accounts.User
  alias Helmsman.Invitations
  alias HelmsmanWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header>
        {dgettext("ui", "注册账号")}
        <:subtitle>
          {dgettext("ui", "已有账号？")}<.link
            navigate={~p"/users/log-in"}
            class="font-medium text-brand-fg hover:underline"
            phx-no-format
          >{dgettext("ui", "登录")}</.link>
        </:subtitle>
      </.header>

      <div
        :if={@invitation}
        id="invitation_summary"
        role="note"
        class="flex gap-2 rounded-field tint-info p-3 text-body text-fg"
      >
        <.icon name="lucide-mail" class="mt-0.5 size-4 shrink-0 text-info" />
        {dgettext("ui", "你被邀请加入 %{workspace}", workspace: @invitation.workspace_name)}
      </div>

      <div
        :if={!@registration_open?}
        id="signup_closed"
        role="note"
        class="flex gap-2 rounded-field tint-info p-3 text-body text-fg"
      >
        <.icon name="lucide-info" class="mt-0.5 size-4 shrink-0 text-info" />
        {dgettext("ui", "注册仅限受邀")}
      </div>

      <.form
        :if={@registration_open?}
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        class="flex flex-col gap-3"
      >
        <.input
          field={@form[:email]}
          type="email"
          label={dgettext("ui", "邮箱")}
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:display_name]}
          type="text"
          label={dgettext("ui", "显示名（可选）")}
          maxlength="64"
        />

        <.button
          type="submit"
          variant="primary"
          phx-disable-with={dgettext("ui", "正在创建…")}
          class="w-full"
        >
          {dgettext("ui", "创建账号")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: HelmsmanWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)
    invitation = invitation(params["invitation"])

    socket =
      socket
      |> assign(
        invitation: invitation,
        registration_open?: invitation != nil or Accounts.registration_open?(),
        client_ip: UserAuth.client_ip(socket)
      )
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    opts = [ip: socket.assigns.client_ip] ++ invitation_opts(socket.assigns.invitation)

    case Accounts.register_user(user_params, opts) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("ui", "确认邮件已发送到 %{email}，请打开邮件中的链接确认账号。", email: user.email)
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :signup_closed} ->
        {:noreply,
         socket
         |> assign(registration_open?: false, invitation: nil)
         |> put_flash(:error, dgettext("ui", "注册仅限受邀"))}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign_form(
           Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
         )
         |> put_flash(:error, dgettext("ui", "请求过于频繁，请稍后再试"))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # A valid invitation token lets the visitor register in invite mode; an
  # invalid one is ignored.
  defp invitation(token) when is_binary(token) do
    case Invitations.preview(token) do
      {:ok, preview} -> %{token: token, workspace_name: preview.workspace_name}
      {:error, :invalid_invitation} -> nil
    end
  end

  defp invitation(_token), do: nil

  defp invitation_opts(%{token: token}), do: [invitation_token: token]
  defp invitation_opts(nil), do: []

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end

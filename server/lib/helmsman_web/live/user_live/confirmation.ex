defmodule HelmsmanWeb.UserLive.Confirmation do
  use HelmsmanWeb, :live_view

  alias Helmsman.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header>{dgettext("ui", "欢迎，%{email}", email: @user.email)}</.header>

      <.form
        :if={!@user.confirmed_at}
        for={@form}
        id="confirmation_form"
        phx-mounted={JS.focus_first()}
        phx-submit="submit"
        action={~p"/users/log-in?_action=confirmed"}
        phx-trigger-action={@trigger_submit}
        class="flex flex-col gap-2"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <.button
          type="submit"
          variant="primary"
          name={@form[:remember_me].name}
          value="true"
          phx-disable-with={dgettext("ui", "正在确认…")}
          class="w-full"
        >
          {dgettext("ui", "确认并保持登录")}
        </.button>
        <.button type="submit" phx-disable-with={dgettext("ui", "正在确认…")} class="w-full">
          {dgettext("ui", "确认并仅本次登录")}
        </.button>
      </.form>

      <.form
        :if={@user.confirmed_at}
        for={@form}
        id="login_form"
        phx-submit="submit"
        phx-mounted={JS.focus_first()}
        action={~p"/users/log-in"}
        phx-trigger-action={@trigger_submit}
        class="flex flex-col gap-2"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <%= if @current_scope do %>
          <.button
            type="submit"
            variant="primary"
            phx-disable-with={dgettext("ui", "正在登录…")}
            class="w-full"
          >
            {dgettext("ui", "登录")}
          </.button>
        <% else %>
          <.button
            type="submit"
            variant="primary"
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with={dgettext("ui", "正在登录…")}
            class="w-full"
          >
            {dgettext("ui", "在此设备上保持登录")}
          </.button>
          <.button type="submit" phx-disable-with={dgettext("ui", "正在登录…")} class="w-full">
            {dgettext("ui", "仅本次登录")}
          </.button>
        <% end %>
      </.form>

      <p
        :if={!@user.confirmed_at}
        class="mt-6 rounded-field border border-border p-3 text-body text-fg-muted"
      >
        {dgettext("ui", "提示：如果更习惯用密码登录，可以在账号设置中设置密码。")}
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, dgettext("ui", "登录链接无效或已过期。"))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end

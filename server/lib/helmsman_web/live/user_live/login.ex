defmodule HelmsmanWeb.UserLive.Login do
  use HelmsmanWeb, :live_view

  alias Helmsman.Accounts
  alias HelmsmanWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header>
        {dgettext("ui", "登录")}
        <:subtitle>
          <%= if @current_scope do %>
            {dgettext("ui", "进行账号的敏感操作前，需要重新验证身份。")}
          <% end %>
          <%= if !@current_scope && @registration_open? do %>
            {dgettext("ui", "还没有账号？")}<.link
              navigate={~p"/users/register"}
              class="font-medium text-brand-fg hover:underline"
              phx-no-format
            >{dgettext("ui", "注册")}</.link>
          <% end %>
        </:subtitle>
      </.header>

      <div
        :if={local_mail_adapter?()}
        id="local-mail-notice"
        role="note"
        class="mb-4 flex gap-2 rounded-field tint-info p-3 text-body text-fg"
      >
        <.icon name="lucide-info" class="mt-0.5 size-4 shrink-0 text-info" />
        <div>
          <p>{dgettext("ui", "当前使用本地邮件适配器。")}</p>
          <p>
            {dgettext("ui", "发出的邮件可在此查看：")}<.link href="/dev/mailbox" class="underline">/dev/mailbox</.link>
          </p>
        </div>
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_magic"
        action={~p"/users/log-in"}
        phx-submit="submit_magic"
        class="flex flex-col gap-3"
      >
        <.input
          readonly={!!@current_scope}
          field={f[:email]}
          type="email"
          label={dgettext("ui", "邮箱")}
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.button type="submit" variant="primary" class="w-full">
          {dgettext("ui", "发送登录链接")} <span aria-hidden="true">→</span>
        </.button>
      </.form>

      <div class="my-5 flex items-center gap-3 text-caption text-fg-subtle" role="separator">
        <span class="h-px flex-1 bg-border"></span>
        {dgettext("ui", "或")}
        <span class="h-px flex-1 bg-border"></span>
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_password"
        action={~p"/users/log-in"}
        phx-submit="submit_password"
        phx-trigger-action={@trigger_submit}
        class="flex flex-col gap-3"
      >
        <.input
          readonly={!!@current_scope}
          field={f[:email]}
          type="email"
          label={dgettext("ui", "邮箱")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label={dgettext("ui", "密码")}
          autocomplete="current-password"
          spellcheck="false"
        />
        <.button
          type="submit"
          variant="primary"
          class="w-full"
          name={@form[:remember_me].name}
          value="true"
        >
          {dgettext("ui", "登录并保持登录")} <span aria-hidden="true">→</span>
        </.button>
        <.button type="submit" class="w-full">
          {dgettext("ui", "仅本次登录")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       registration_open?: Accounts.registration_open?(),
       client_ip: UserAuth.client_ip(socket)
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    case Accounts.request_login_link(
           email,
           socket.assigns.client_ip,
           &url(~p"/users/log-in/#{&1}")
         ) do
      :ok ->
        info = dgettext("ui", "如果该邮箱已注册，你很快会收到一封登录邮件。")

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, dgettext("ui", "请求过于频繁，请稍后再试"))}
    end
  end

  defp local_mail_adapter? do
    Application.get_env(:helmsman, Helmsman.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end

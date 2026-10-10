defmodule HelmsmanWeb.UserLive.Settings do
  use HelmsmanWeb, :live_view

  alias Helmsman.Accounts
  alias HelmsmanWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form
        for={@display_name_form}
        id="display_name_form"
        phx-submit="update_display_name"
        phx-change="validate_display_name"
      >
        <.input
          field={@display_name_form[:display_name]}
          type="text"
          label="Display name"
          maxlength="64"
          required
        />
        <.button variant="primary" phx-disable-with="Saving...">Save Display Name</.button>
      </.form>

      <div class="divider" />

      <div :if={!@sudo_mode?} id="reauthenticate_notice">
        <p>
          <.link navigate={~p"/users/log-in"} class="font-semibold underline">Log in again</.link>
          to change your email or password.
        </p>
      </div>

      <.form
        :if={@sudo_mode?}
        for={@email_form}
        id="email_form"
        phx-submit="update_email"
        phx-change="validate_email"
      >
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div :if={@sudo_mode?} class="divider" />

      <.form
        :if={@sudo_mode?}
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
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
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>
    </Layouts.app>
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
              put_flash(socket, :info, "Email changed successfully.")

            {:error, _} ->
              put_flash(socket, :error, "Email change link is invalid or it has expired.")
          end

        {:ok, push_navigate(socket, to: ~p"/users/settings")}

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:sudo_mode?, Accounts.sudo_mode?(user))
      |> assign(:display_name_form, to_form(Accounts.change_user_display_name(user)))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

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
         |> put_flash(:info, "Display name updated successfully.")}

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

        info = "A link to confirm your email change has been sent to the new address."
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
    |> put_flash(:error, "You must log in again to change your email or password.")
  end
end

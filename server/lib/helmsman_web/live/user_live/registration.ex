defmodule HelmsmanWeb.UserLive.Registration do
  use HelmsmanWeb, :live_view

  alias Helmsman.Accounts
  alias Helmsman.Accounts.User
  alias Helmsman.Invitations
  alias HelmsmanWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <div :if={@invitation} id="invitation_summary" class="alert alert-info">
          你被邀请加入 {@invitation.workspace_name}
        </div>

        <div :if={!@registration_open?} id="signup_closed" class="alert alert-info">
          注册仅限受邀
        </div>

        <.form
          :if={@registration_open?}
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:display_name]}
            type="text"
            label="Display name (optional)"
            maxlength="64"
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
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
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :signup_closed} ->
        {:noreply,
         socket
         |> assign(registration_open?: false, invitation: nil)
         |> put_flash(:error, "注册仅限受邀")}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign_form(
           Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
         )
         |> put_flash(:error, "请求过于频繁，请稍后再试")}
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

defmodule HelmsmanWeb.UserAuth do
  @moduledoc """
  Authentication plugs and LiveView `on_mount` hooks: logging users in and
  out, loading the current scope and requiring authentication or sudo mode.
  """

  use HelmsmanWeb, :verified_routes
  use Gettext, backend: HelmsmanWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Helmsman.Accounts
  alias Helmsman.Accounts.Scope
  alias Helmsman.Policy
  alias Helmsman.Workspaces
  alias HelmsmanWeb.Plugs.TrustedProxies

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_helmsman_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> delete_session(:user_return_to)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out and redirects to `to` (default `/`).

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn, to \\ ~p"/") do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      HelmsmanWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, remember_me_options())
    |> redirect(to: to)
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, remember_me_options())
  end

  # `Secure` follows the public URL's scheme, a runtime setting.
  defp remember_me_options, do: HelmsmanWeb.Endpoint.put_secure(@remember_me_options)

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      HelmsmanWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:require_instance_admin` - Must run after `:require_authenticated`.
      Raises `HelmsmanWeb.NotFoundError` (404) unless the user is an
      instance administrator (the check of `/admin/github`:
      `Helmsman.Policy`'s `:manage_github_app`), so the page does not
      reveal itself to anyone else.

    * `:require_workspace` - Must run after `:require_authenticated`. Puts
      the workspace of the `slug` route parameter, the user's role and
      human identity in the current_scope. Raises
      `HelmsmanWeb.NotFoundError` (404) when the workspace does not exist
      or the user is not a member, so both cases look the same.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule HelmsmanWeb.PageLive do
        use HelmsmanWeb, :live_view

        on_mount {HelmsmanWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{HelmsmanWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, dgettext("ui", "请先登录。"))
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_instance_admin, _params, _session, socket) do
    case Policy.authorize(socket.assigns.current_scope, :manage_github_app) do
      :ok -> {:cont, socket}
      {:error, _reason} -> raise HelmsmanWeb.NotFoundError
    end
  end

  def on_mount(:require_workspace, %{"slug" => slug}, _session, socket) do
    %Scope{user: user} = scope = socket.assigns.current_scope

    case Workspaces.fetch_for_user(user, slug) do
      {:ok, %{workspace: workspace, membership: membership, actor: actor}} ->
        scope = %{Scope.put_workspace(scope, workspace, membership, actor) | via: :web}
        {:cont, Phoenix.Component.assign(socket, :current_scope, scope)}

      {:error, :not_found} ->
        raise HelmsmanWeb.NotFoundError
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, dgettext("ui", "请重新登录以验证身份。"))
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc """
  Returns the client IP of a LiveView socket (from the `:peer_data` connect
  info; a trusted proxy's `X-Forwarded-For` from `:x_headers`, as
  `HelmsmanWeb.Plugs.TrustedProxies` does for requests), or `nil` when it
  is not available.
  """
  def client_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        TrustedProxies.client_ip(address, headers)

      _ ->
        nil
    end
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, dgettext("ui", "请先登录。"))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for workspace pages: remembers the slug of a workspace page loaded over
  HTTP by a logged-in user as the most recently visited workspace (`/` goes
  back there). The session is cleared on log in and log out.
  """
  def remember_workspace(%{method: "GET", path_params: %{"slug" => slug}} = conn, _opts)
      when is_binary(slug) do
    if logged_in?(conn), do: put_session(conn, :last_workspace_slug, slug), else: conn
  end

  def remember_workspace(conn, _opts), do: conn

  @doc """
  Plug for the invitation page: a visitor who is not logged in comes back to it
  after logging in or registering (`log_in_user/3` reads `:user_return_to`).
  """
  def store_invitation_return_to(%{method: "GET"} = conn, _opts) do
    if logged_in?(conn), do: conn, else: put_session(conn, :user_return_to, conn.request_path)
  end

  def store_invitation_return_to(conn, _opts), do: conn

  defp logged_in?(conn), do: match?(%Scope{user: %Accounts.User{}}, conn.assigns[:current_scope])

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end

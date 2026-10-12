defmodule HelmsmanWeb.UserSessionController do
  use HelmsmanWeb, :controller

  alias Helmsman.Accounts
  alias HelmsmanWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, dgettext("ui", "账号已确认。"))
  end

  def create(conn, params) do
    create(conn, params, dgettext("ui", "欢迎回来！"))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, dgettext("ui", "链接无效或已过期。"))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    case Accounts.login_user_by_password(email, password, conn.remote_ip) do
      {:ok, user} ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :invalid_credentials} ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, dgettext("ui", "邮箱或密码错误"))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, dgettext("ui", "请求过于频繁，请稍后再试"))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user

    with true <- Accounts.sudo_mode?(user),
         {:ok, {_user, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(params, dgettext("ui", "密码已更新。"))
    else
      false ->
        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:error, dgettext("ui", "需要重新登录才能修改邮箱或密码。"))
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, dgettext("ui", "密码更新失败，请重试。"))
        |> redirect(to: ~p"/users/settings")
    end
  end

  # Only the invitation page may be returned to (「换个账号」), never an arbitrary URL.
  @return_to ~r{\A/invite/[A-Za-z0-9_-]+\z}

  def delete(conn, params) do
    to =
      case params["return_to"] do
        path when is_binary(path) -> if path =~ @return_to, do: path, else: ~p"/"
        _ -> ~p"/"
      end

    conn
    |> put_flash(:info, dgettext("ui", "已退出登录。"))
    |> UserAuth.log_out_user(to)
  end
end

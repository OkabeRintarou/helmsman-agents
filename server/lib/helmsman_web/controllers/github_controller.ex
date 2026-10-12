defmodule HelmsmanWeb.GitHubController do
  @moduledoc """
  The GitHub flows that go through github.com (design decision 9):

    * `GET /admin/github` - instance administrators: a minimal page that
      starts the App manifest flow, or shows the configured App
      (`Admin.GitHubLive` replaces it)
    * `GET /admin/github/callback` - the manifest flow's return
    * `GET /w/:slug/settings/github/connect` - workspace owners / admins:
      redirects to the App's installation page
    * `GET /github/setup` - the installation's return (with OAuth `code`)

  `state` is a `Phoenix.Token` valid 10 minutes, bound to the user (and
  for installations to the workspace).
  """

  use HelmsmanWeb, :controller

  alias Helmsman.Accounts.Scope
  alias Helmsman.GitHub
  alias Helmsman.Policy
  alias Helmsman.Workspaces

  @manifest_salt "github-manifest"
  @install_salt "github-install"
  @state_max_age 600

  ## App manifest flow

  def admin(conn, params) do
    scope = conn.assigns.current_scope

    case GitHub.app_overview(scope) do
      {:error, :forbidden} ->
        forbidden(conn)

      {:ok, %{configured?: true} = overview} ->
        render(conn, :admin, overview: overview, form: nil)

      {:ok, %{configured?: false}} ->
        render_manifest_form(conn, scope, params)
    end
  end

  defp render_manifest_form(conn, scope, params) do
    input = %{
      name: params |> Map.get("name", "Helmsman") |> String.trim(),
      owner_org: Map.get(params, "owner_org", ""),
      public?: Map.get(params, "public") == "true"
    }

    state = Phoenix.Token.sign(conn, @manifest_salt, %{u: scope.user.id})

    case GitHub.manifest(scope, Map.put(input, :base_url, url(~p"/"))) do
      {:ok, %{action_url: action_url, manifest_json: manifest}} ->
        form = %{
          action_url: action_url <> "?" <> URI.encode_query(%{state: state}),
          manifest: manifest,
          input: input,
          error: nil
        }

        render(conn, :admin, overview: nil, form: form)

      {:error, :invalid_params} ->
        form = %{action_url: nil, manifest: nil, input: input, error: :invalid_params}
        render(conn, :admin, overview: nil, form: form)

      {:error, _reason} ->
        forbidden(conn)
    end
  end

  def manifest_callback(conn, params) do
    scope = conn.assigns.current_scope

    with :ok <- Policy.authorize(scope, :manage_github_app),
         :ok <- verify_manifest_state(conn, scope, params["state"]),
         code when is_binary(code) and code != "" <- params["code"] do
      case GitHub.complete_manifest(scope, code) do
        {:ok, _overview} ->
          conn
          |> put_flash(:info, dgettext("ui", "GitHub App 已创建。"))
          |> redirect(to: ~p"/admin/github")

        {:error, :already_configured} ->
          back_to_admin(conn, dgettext("ui", "GitHub App 已经配置过了。"))

        {:error, _reason} ->
          back_to_admin(conn, dgettext("ui", "无法从 GitHub 取得 App 凭据，请重试。"))
      end
    else
      {:error, :forbidden} -> forbidden(conn)
      _invalid -> back_to_admin(conn, dgettext("ui", "链接无效或已过期，请重新创建。"))
    end
  end

  defp verify_manifest_state(conn, scope, state) when is_binary(state) do
    case Phoenix.Token.verify(conn, @manifest_salt, state, max_age: @state_max_age) do
      {:ok, %{u: user_id}} when user_id == scope.user.id -> :ok
      _ -> :error
    end
  end

  defp verify_manifest_state(_conn, _scope, _state), do: :error

  defp back_to_admin(conn, message),
    do: conn |> put_flash(:error, message) |> redirect(to: ~p"/admin/github")

  ## Installation flow

  def connect(conn, %{"slug" => slug}) do
    scope = workspace_scope!(conn.assigns.current_scope, slug)

    with :ok <- Policy.authorize(scope, :manage_github),
         state =
           Phoenix.Token.sign(conn, @install_salt, %{w: scope.workspace.id, u: scope.user.id}),
         {:ok, url} <- GitHub.install_url(state) do
      redirect(conn, external: url)
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :github_not_configured} ->
        conn
        |> put_flash(:error, dgettext("ui", "实例管理员还没有配置 GitHub App。"))
        |> redirect(to: ~p"/w/#{scope.workspace.slug}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, dgettext("ui", "暂时无法连接 GitHub，请稍后重试。"))
        |> redirect(to: ~p"/w/#{scope.workspace.slug}")
    end
  end

  def setup(conn, params) do
    user_scope = conn.assigns.current_scope

    with {:ok, workspace_id} <- verify_install_state(conn, user_scope, params["state"]),
         {:ok, scope} <- workspace_scope(user_scope, workspace_id) do
      result =
        case parse_id(params["installation_id"]) do
          {:ok, installation_id} ->
            GitHub.connect_installation(scope, installation_id, params["code"])

          :error ->
            {:error, :installation_not_accessible}
        end

      conn
      |> put_flash(flash_kind(result), setup_message(result))
      |> redirect(to: ~p"/w/#{scope.workspace.slug}")
    else
      _invalid ->
        conn
        |> put_flash(:error, dgettext("ui", "连接链接无效或已过期，请回到工作区重新点「连接 GitHub」。"))
        |> redirect(to: ~p"/")
    end
  end

  defp verify_install_state(conn, scope, state) when is_binary(state) do
    case Phoenix.Token.verify(conn, @install_salt, state, max_age: @state_max_age) do
      {:ok, %{w: workspace_id, u: user_id}} when user_id == scope.user.id -> {:ok, workspace_id}
      _ -> :error
    end
  end

  defp verify_install_state(_conn, _scope, _state), do: :error

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp flash_kind({:ok, _}), do: :info
  defp flash_kind({:error, _}), do: :error

  defp setup_message({:ok, _installation}), do: dgettext("ui", "已连接 GitHub，正在同步仓库。")

  defp setup_message({:error, :forbidden}),
    do: dgettext("ui", "只有工作区的所有者或管理员可以连接 GitHub。")

  defp setup_message({:error, :oauth_required}),
    do: dgettext("ui", "GitHub App 没有开启「安装时请求用户授权（OAuth）」，请在 App 设置中开启后重试。")

  defp setup_message({:error, :installation_taken}),
    do: dgettext("ui", "该 GitHub 安装已被其他工作区使用。")

  defp setup_message({:error, :already_connected}),
    do: dgettext("ui", "工作区已连接了另一个 GitHub 安装，请先断开。")

  defp setup_message({:error, :stale}),
    do: dgettext("ui", "GitHub 安装状态刚刚发生变化，请重新点「连接 GitHub」。")

  defp setup_message({:error, :installation_not_accessible}),
    do: dgettext("ui", "无法确认你可以访问该 GitHub 安装。")

  defp setup_message({:error, _reason}), do: dgettext("ui", "暂时无法连接 GitHub，请稍后重试。")

  ## Helpers

  defp workspace_scope!(%Scope{user: user} = scope, slug) do
    case Workspaces.fetch_for_user(user, slug) do
      {:ok, access} -> put_workspace(scope, access)
      {:error, :not_found} -> raise HelmsmanWeb.NotFoundError
    end
  end

  defp workspace_scope(%Scope{user: user} = scope, workspace_id) do
    with %{slug: slug} <- Workspaces.get(workspace_id),
         {:ok, access} <- Workspaces.fetch_for_user(user, slug) do
      {:ok, put_workspace(scope, access)}
    else
      _ -> :error
    end
  end

  defp put_workspace(scope, %{workspace: workspace, membership: membership, actor: actor}),
    do: %{Scope.put_workspace(scope, workspace, membership, actor) | via: :web}

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> put_view(html: HelmsmanWeb.ErrorHTML)
    |> render(:"403")
    |> halt()
  end
end

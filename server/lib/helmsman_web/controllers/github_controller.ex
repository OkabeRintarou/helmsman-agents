defmodule HelmsmanWeb.GitHubController do
  @moduledoc """
  The GitHub flows that go through github.com (design decision 9):

    * `GET /admin/github/callback` - the return of the App manifest flow
      started on `/admin/github` (`HelmsmanWeb.Admin.GitHubLive`)
    * `GET /w/:slug/settings/github/connect` - workspace owners / admins:
      redirects to the App's installation page
    * `GET /github/setup` - the installation's return (with OAuth `code`)

  `state` is a `Phoenix.Token` valid 10 minutes, bound to the user (and
  for installations to the workspace); see `HelmsmanWeb.GitHubState`. The
  installation flow returns to the workspace's GitHub settings page
  (add-github-ui D4).
  """

  use HelmsmanWeb, :controller

  alias Helmsman.Accounts.Scope
  alias Helmsman.GitHub
  alias Helmsman.Policy
  alias Helmsman.Workspaces
  alias HelmsmanWeb.GitHubState

  ## App manifest flow

  def manifest_callback(conn, params) do
    scope = conn.assigns.current_scope

    with :ok <- Policy.authorize(scope, :manage_github_app),
         :ok <- GitHubState.verify_manifest(params["state"], scope.user.id),
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

  defp back_to_admin(conn, message),
    do: conn |> put_flash(:error, message) |> redirect(to: ~p"/admin/github")

  ## Installation flow

  def connect(conn, %{"slug" => slug}) do
    scope = workspace_scope!(conn.assigns.current_scope, slug)

    with :ok <- Policy.authorize(scope, :manage_github),
         state = GitHubState.sign_install(scope.workspace.id, scope.user.id),
         {:ok, url} <- GitHub.install_url(state) do
      redirect(conn, external: url)
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :github_not_configured} ->
        conn
        |> put_flash(:error, dgettext("ui", "实例管理员还没有配置 GitHub App。"))
        |> redirect(to: settings_path(scope))

      {:error, _reason} ->
        conn
        |> put_flash(:error, dgettext("ui", "暂时无法连接 GitHub，请稍后重试。"))
        |> redirect(to: settings_path(scope))
    end
  end

  def setup(conn, params) do
    user_scope = conn.assigns.current_scope

    with {:ok, workspace_id} <- GitHubState.verify_install(params["state"], user_scope.user.id),
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
      |> redirect(to: settings_path(scope))
    else
      _invalid ->
        conn
        |> put_flash(:error, dgettext("ui", "连接链接无效或已过期，请回到工作区重新点「连接 GitHub」。"))
        |> redirect(to: ~p"/")
    end
  end

  defp settings_path(scope), do: ~p"/w/#{scope.workspace.slug}/settings/github"

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

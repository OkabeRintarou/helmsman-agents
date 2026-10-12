defmodule HelmsmanWeb.PageController do
  @moduledoc """
  `/` only redirects (spec web-workspace-entry 根路径跳转, design D3): to the log-in
  page, the most recently visited workspace the user still belongs to, their first
  workspace by name, or `/workspaces/new`.
  """
  use HelmsmanWeb, :controller

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Workspaces

  def home(%{assigns: %{current_scope: %Scope{user: %User{} = user}}} = conn, _params) do
    workspaces = Enum.map(Workspaces.list_for_user(user), & &1.workspace)
    last = get_session(conn, :last_workspace_slug)

    to =
      case Enum.find(workspaces, &(&1.slug == last)) || List.first(workspaces) do
        nil -> ~p"/workspaces/new"
        workspace -> "/w/#{workspace.slug}"
      end

    redirect(conn, to: to)
  end

  def home(conn, _params), do: redirect(conn, to: ~p"/users/log-in")
end

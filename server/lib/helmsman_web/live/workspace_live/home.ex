defmodule HelmsmanWeb.WorkspaceLive.Home do
  @moduledoc """
  Placeholder workspace home page: shows the workspace name and the current
  user's role. The workspace pages change replaces it.
  """

  use HelmsmanWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 id="workspace-name" class="text-2xl font-semibold">{@current_scope.workspace.name}</h1>
      <p id="workspace-role">{@current_scope.role}</p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, socket.assigns.current_scope.workspace.name)}
  end
end

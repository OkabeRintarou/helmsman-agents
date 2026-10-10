defmodule HelmsmanWeb.WorkspaceLive.Home do
  @moduledoc """
  Placeholder workspace home page: shows the workspace name and the current
  user's role. The workspace pages change replaces it.
  """

  use HelmsmanWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@current_scope.workspace.name} />
      </:header>
      <div class="px-6 py-4">
        <p id="workspace-name" class="text-heading font-semibold text-fg">
          {@current_scope.workspace.name}
        </p>
        <p id="workspace-role" class="text-body text-fg-muted">{@current_scope.role}</p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, socket.assigns.current_scope.workspace.name)}
  end
end

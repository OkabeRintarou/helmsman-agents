defmodule HelmsmanWeb.WorkspaceLive.Home do
  @moduledoc """
  Placeholder workspace home page: shows the workspace name and the current
  user's role. The workspace pages change replaces it.

  It also lists the user's spec to-do list, 待处理的规格 (add-spec-workflow-ui D16:
  `Helmsman.TaskSpecs.attention/1`), re-read on `{:spec_attention_changed, _}` from the
  workspace topic (forwarded by the shell). The section is a component so the future
  dashboard can reuse it.
  """

  use HelmsmanWeb, :live_view

  alias HelmsmanWeb.{SpecComponents, SpecData}

  @empty %{pending_approval: [], review_requests: []}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@current_scope.workspace.name} />
      </:header>
      <div class="flex flex-col gap-6 px-6 py-4">
        <div>
          <p id="workspace-name" class="text-heading font-semibold text-fg">
            {@current_scope.workspace.name}
          </p>
          <p id="workspace-role" class="text-body text-fg-muted">{@current_scope.role}</p>
        </div>
        <SpecComponents.attention attention={@attention} slug={@current_scope.workspace.slug} />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, socket.assigns.current_scope.workspace.name)
     |> load_attention()}
  end

  @impl true
  def handle_info({:spec_attention_changed, _workspace_id}, socket),
    do: {:noreply, load_attention(socket)}

  defp load_attention(socket) do
    attention =
      case SpecData.attention(socket.assigns.current_scope) do
        {:ok, attention} -> attention
        _ -> @empty
      end

    assign(socket, :attention, attention)
  end
end

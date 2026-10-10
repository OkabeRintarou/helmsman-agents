defmodule HelmsmanWeb.Shell do
  @moduledoc """
  `on_mount` hook for workspace pages (last in the `live_session :workspace` chain).

  * Assigns `@shell` (navigation, the user's workspaces, recently visited tasks from the
    LiveSocket connect params) for `HelmsmanWeb.Layouts.app/1`.
  * Tracks the current path (`handle_params`) to mark the current navigation item.
  * Subscribes to `user:<id>` and handles membership changes (design DR-8):
    `{:membership_changed, workspace_id, :removed | {:role, role}}` — removal from the
    current workspace redirects to `/` with a flash; a role change re-mounts the current
    page; messages about other workspaces are ignored.
  * Handles the `hm:switch-workspace` event from the workspace switcher.

  The scope is read from `socket.assigns.current_scope` (`user`, `workspace`). For a
  `Helmsman.Accounts.Scope` the switcher lists `Helmsman.Workspaces.list_for_user/1`; the
  `/dev/ui` demo scope (a plain map) carries its own `workspaces`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Workspaces
  alias HelmsmanWeb.Nav

  @max_recent 10

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns[:current_scope]

    user_id = user_id(scope)

    if connected?(socket) && user_id,
      do: Phoenix.PubSub.subscribe(Helmsman.PubSub, topic(user_id))

    socket =
      socket
      |> assign(:shell, %{
        nav: [],
        nav_items: socket.assigns[:shell_nav_items] || Nav.items(),
        workspaces: workspaces(scope),
        recent_tasks: recent_tasks(socket),
        path: nil,
        uri: nil
      })
      |> attach_hook(:hm_shell_params, :handle_params, &handle_params/3)
      |> attach_hook(:hm_shell_info, :handle_info, &handle_info/2)
      |> attach_hook(:hm_shell_event, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  @doc "PubSub topic carrying membership changes for a user."
  def topic(user_id), do: "user:#{user_id}"

  defp handle_params(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    shell = socket.assigns.shell
    scope = socket.assigns[:current_scope]

    shell = %{
      shell
      | path: path,
        uri: if(query, do: "#{path}?#{query}", else: path),
        nav: Nav.items_for(scope, path, shell.nav_items)
    }

    {:cont, assign(socket, :shell, shell)}
  end

  defp handle_info({:membership_changed, workspace_id, change}, socket) do
    workspace = current_workspace(socket.assigns[:current_scope])

    cond do
      workspace == nil or workspace.id != workspace_id ->
        {:halt, socket}

      change == :removed ->
        message = dgettext("ui", "你已被移出 %{workspace}", workspace: workspace.name)
        {:halt, socket |> put_flash(:error, message) |> redirect(to: "/")}

      match?({:role, _}, change) ->
        {:halt, push_navigate(socket, to: socket.assigns.shell.uri || "/w/#{workspace.slug}")}

      true ->
        {:halt, socket}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("hm:switch-workspace", %{"slug" => slug}, socket) do
    if Enum.any?(socket.assigns.shell.workspaces, &(&1.slug == slug)) do
      {:halt, redirect(socket, to: "/w/#{slug}")}
    else
      {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp user_id(%{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil

  defp current_workspace(%{workspace: %{} = workspace}), do: workspace
  defp current_workspace(_scope), do: nil

  defp workspaces(nil), do: []

  defp workspaces(%Scope{user: %User{} = user}),
    do: user |> Workspaces.list_for_user() |> Enum.map(& &1.workspace)

  defp workspaces(scope) do
    case Map.get(scope, :workspaces) do
      list when is_list(list) -> list
      _ -> List.wrap(current_workspace(scope))
    end
  end

  defp recent_tasks(socket) do
    with true <- connected?(socket),
         %{"recent_tasks" => list} when is_list(list) <- get_connect_params(socket) do
      list |> Enum.filter(&is_binary/1) |> Enum.take(@max_recent)
    else
      _ -> []
    end
  end
end

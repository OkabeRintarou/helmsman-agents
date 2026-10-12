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
  * Subscribes to `workspace:<id>` (add-workspace-settings-ui D8, the only subscription
    to that topic for workspace pages): `{:workspace_updated, %{id, name, slug}}` renames
    the workspace in place (the title suffix lives in the root layout, so it is updated
    by the `hm:title-suffix` event in `app.js`) or follows a slug change; `{:projects_changed}` reloads
    `shell.projects` and the navigation. Messages the shell does not consume go on to the
    page when it exports `handle_info/2` (`HelmsmanWeb.LiveFallback` ignores the rest),
    otherwise they stop here.
  * Assigns `shell.projects` (the sidebar's 项目 group) and `shell.can_create_task?`.
  * Handles the `hm:switch-workspace` event from the workspace switcher.

  The scope is read from `socket.assigns.current_scope` (`user`, `workspace`). For a
  `Helmsman.Accounts.Scope` the switcher lists `Helmsman.Workspaces.list_for_user/1`; the
  `/dev/ui` demo scope (a plain map) carries its own `workspaces`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Events
  alias Helmsman.Policy
  alias Helmsman.Projects
  alias Helmsman.Workspaces
  alias HelmsmanWeb.Nav

  @max_recent 10

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns[:current_scope]

    user_id = user_id(scope)

    if connected?(socket) && user_id,
      do: Phoenix.PubSub.subscribe(Helmsman.PubSub, topic(user_id))

    if connected?(socket), do: subscribe_workspace(scope)

    socket =
      socket
      |> assign(:shell, %{
        nav: [],
        nav_items: socket.assigns[:shell_nav_items] || Nav.items(),
        workspaces: workspaces(scope),
        projects: projects(scope),
        can_create_task?: can_create_task?(scope),
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
        nav: nav(scope, path, shell)
    }

    {:cont, assign(socket, :shell, shell)}
  end

  defp nav(scope, path, shell),
    do: Nav.items_for(scope, path, Nav.project_items(shell.projects) ++ shell.nav_items)

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

  defp handle_info({:workspace_updated, %{id: id, name: name, slug: slug}}, socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: ^id, slug: ^slug}} = scope ->
        {:halt, rename_workspace(socket, scope, name)}

      %{workspace: %{id: ^id, slug: old}} ->
        message = dgettext("ui", "工作区地址已改为 /w/%{slug}", slug: slug)
        uri = socket.assigns.shell.uri || "/w/#{old}"
        to = String.replace_prefix(uri, "/w/#{old}", "/w/#{slug}")
        {:halt, socket |> put_flash(:info, message) |> push_navigate(to: to)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info({:projects_changed} = message, socket) do
    scope = socket.assigns[:current_scope]
    shell = %{socket.assigns.shell | projects: projects(scope)}
    shell = %{shell | nav: nav(scope, shell.path, shell)}
    forward(message, assign(socket, :shell, shell))
  end

  defp handle_info(message, socket), do: forward(message, socket)

  # Pages without handle_info/2 would log "undefined handle_info" for every broadcast.
  defp forward(_message, socket) do
    if function_exported?(socket.view, :handle_info, 2),
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp rename_workspace(socket, scope, name) do
    workspace = %{scope.workspace | name: name}

    workspaces =
      Enum.map(socket.assigns.shell.workspaces, fn
        %{id: id} = ws when id == workspace.id -> %{ws | name: name}
        ws -> ws
      end)

    socket
    |> assign(:current_scope, %{scope | workspace: workspace})
    |> assign(:shell, %{socket.assigns.shell | workspaces: workspaces})
    |> push_event("hm:title-suffix", %{suffix: " · #{name}"})
  end

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

  defp subscribe_workspace(%Scope{workspace: %{id: id}}) when is_integer(id),
    do: Events.subscribe(Events.topic(:workspace, id))

  defp subscribe_workspace(_scope), do: :ok

  # The /dev/ui demo scope (a plain map) has no projects and may open the new-task panel.
  defp projects(%Scope{workspace: %{}} = scope) do
    case Projects.list(scope) do
      {:ok, projects} -> projects
      {:error, _} -> []
    end
  end

  defp projects(_scope), do: []

  defp can_create_task?(%Scope{workspace: %{}} = scope),
    do: Policy.authorize(scope, :create_task) == :ok

  defp can_create_task?(_scope), do: true

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

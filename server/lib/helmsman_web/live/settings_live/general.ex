defmodule HelmsmanWeb.SettingsLive.General do
  @moduledoc """
  General settings `/w/:slug/settings` (spec web-workspace-settings 常规设置 / 退出工作区,
  design D6): the workspace name (owner, admin), the slug (owner, after a confirmation)
  and leaving the workspace.

  After a slug change the page swaps `current_scope.workspace` before navigating, so the
  shell treats the `{:workspace_updated, …}` broadcast as a rename and does not
  navigate a second time.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SettingsComponents

  alias Helmsman.{Members, Policy, Workspaces}
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanWeb.FormErrors
  alias HelmsmanWeb.SettingsLive.Errors

  @impl true
  def mount(_params, _session, socket) do
    %{workspace: workspace} = scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "常规"),
       can_rename?: Policy.authorize(scope, :update_workspace) == :ok,
       can_change_slug?: Policy.authorize(scope, :change_workspace_slug) == :ok,
       name: workspace.name,
       name_errors: [],
       slug: workspace.slug,
       slug_errors: [],
       pending_slug: nil,
       confirm_leave?: false
     )
     |> load_owners()}
  end

  defp load_owners(socket) do
    sole_owner? =
      case Members.list(socket.assigns.current_scope) do
        {:ok, members} ->
          socket.assigns.current_scope.role == :owner and
            Enum.count(members, &(&1.role == :owner)) <= 1

        {:error, _} ->
          false
      end

    assign(socket, :sole_owner?, sole_owner?)
  end

  ## Name

  @impl true
  def handle_event("validate_name", %{"workspace" => %{"name" => name}}, socket) do
    {:noreply, assign(socket, name: name, name_errors: field_errors(socket, :name, name))}
  end

  def handle_event("save_name", %{"workspace" => %{"name" => name}}, socket) do
    case Workspaces.update(socket.assigns.current_scope, %{"name" => name}) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_workspace(workspace)
         |> assign(name: workspace.name, name_errors: [])
         |> put_flash(:info, dgettext("ui", "已保存"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, name: name, name_errors: errors_of(changeset, :name))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  ## Slug

  def handle_event("validate_slug", %{"workspace" => %{"slug" => slug}}, socket) do
    {:noreply, assign(socket, slug: slug, slug_errors: field_errors(socket, :slug, slug))}
  end

  def handle_event("request_slug", %{"workspace" => %{"slug" => slug}}, socket) do
    errors = field_errors(socket, :slug, slug)
    current = socket.assigns.current_scope.workspace.slug
    normalized = String.downcase(slug)

    cond do
      errors != [] -> {:noreply, assign(socket, slug: slug, slug_errors: errors)}
      normalized == current -> {:noreply, assign(socket, slug: slug, slug_errors: [])}
      true -> {:noreply, assign(socket, slug: slug, slug_errors: [], pending_slug: normalized)}
    end
  end

  def handle_event("cancel_slug", _params, socket),
    do: {:noreply, assign(socket, :pending_slug, nil)}

  def handle_event("confirm_slug", %{"slug" => slug}, socket) do
    case Workspaces.update(socket.assigns.current_scope, %{"slug" => slug}) do
      {:ok, workspace} ->
        message = dgettext("ui", "工作区地址已改为 /w/%{slug}", slug: workspace.slug)

        {:noreply,
         socket
         |> put_workspace(workspace)
         |> assign(pending_slug: nil)
         |> put_flash(:info, message)
         |> push_navigate(to: "/w/#{workspace.slug}/settings")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, pending_slug: nil, slug_errors: errors_of(changeset, :slug))}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:pending_slug, nil) |> put_flash(:error, Errors.message(reason))}
    end
  end

  ## Leaving

  def handle_event("ask_leave", _params, socket) do
    if socket.assigns.sole_owner?,
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :confirm_leave?, true)}
  end

  def handle_event("cancel_leave", _params, socket),
    do: {:noreply, assign(socket, :confirm_leave?, false)}

  def handle_event("leave", _params, socket) do
    workspace = socket.assigns.current_scope.workspace

    case Members.leave(socket.assigns.current_scope) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "你已退出 %{workspace}", workspace: workspace.name))
         |> redirect(to: ~p"/")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:confirm_leave?, false)
         |> load_owners()
         |> put_flash(:error, Errors.message(reason))}
    end
  end

  @impl true
  def handle_info({:members_changed}, socket), do: {:noreply, load_owners(socket)}

  defp put_workspace(socket, %Workspace{} = workspace) do
    scope = socket.assigns.current_scope
    assign(socket, :current_scope, %{scope | workspace: workspace})
  end

  defp field_errors(socket, field, value) do
    socket.assigns.current_scope.workspace
    |> Workspace.changeset(%{field => value})
    |> errors_of(field)
  end

  defp errors_of(changeset, field), do: Map.get(FormErrors.messages(changeset), field, [])

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_page tab={:general} flash={@flash} current_scope={@current_scope} shell={@shell}>
      <.settings_section id="workspace-section" title={dgettext("ui", "工作区")}>
        <.form
          :if={@can_rename?}
          for={%{}}
          as={:workspace}
          id="workspace-name-form"
          phx-change="validate_name"
          phx-submit="save_name"
          class="flex flex-col gap-2 py-2 sm:flex-row sm:items-start"
        >
          <div class="min-w-0 flex-1">
            <.input
              id="workspace-name"
              name="workspace[name]"
              label={dgettext("ui", "名称")}
              value={@name}
              errors={@name_errors}
              layout={:row}
              autocomplete="off"
            />
          </div>
          <.button
            id="workspace-name-save"
            type="submit"
            class="sm:mt-2"
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {dgettext("ui", "保存")}
          </.button>
        </.form>
        <.property_list :if={!@can_rename?}>
          <.property_row label={dgettext("ui", "名称")}>
            <span id="workspace-name-text">{@current_scope.workspace.name}</span>
          </.property_row>
        </.property_list>

        <.form
          :if={@can_change_slug?}
          for={%{}}
          as={:workspace}
          id="workspace-slug-form"
          phx-change="validate_slug"
          phx-submit="request_slug"
          class="flex flex-col gap-2 border-t border-border py-2 sm:flex-row sm:items-start"
        >
          <div class="min-w-0 flex-1">
            <.input
              id="workspace-slug"
              name="workspace[slug]"
              label={dgettext("ui", "地址")}
              value={@slug}
              errors={@slug_errors}
              help={dgettext("ui", "2–39 位小写字母、数字或 -，以字母或数字开头")}
              layout={:row}
              autocomplete="off"
              spellcheck="false"
              class="font-mono"
            />
          </div>
          <.button id="workspace-slug-save" type="submit" class="sm:mt-2">
            {dgettext("ui", "保存")}
          </.button>
        </.form>
        <.property_list :if={!@can_change_slug?}>
          <.property_row label={dgettext("ui", "地址")}>
            <span class="flex flex-col">
              <span id="workspace-slug-text" class="font-mono">
                /w/{@current_scope.workspace.slug}
              </span>
              <span
                :if={@can_rename?}
                id="workspace-slug-owner-only"
                class="text-caption text-fg-muted"
              >
                {dgettext("ui", "只有所有者能修改地址")}
              </span>
            </span>
          </.property_row>
        </.property_list>
      </.settings_section>

      <.settings_section id="danger-section" title={dgettext("ui", "危险操作")} danger>
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div class="min-w-0">
            <p class="text-body font-medium text-fg">{dgettext("ui", "退出工作区")}</p>
            <p class="text-caption text-fg-muted">
              {dgettext("ui", "之后需要重新被邀请才能加入")}
            </p>
          </div>
          <.button
            id="leave-workspace"
            variant="danger"
            icon="lucide-log-out"
            phx-click="ask_leave"
            disabled_reason={if(@sole_owner?, do: dgettext("ui", "你是唯一的所有者，请先把其他成员设为所有者"))}
          >
            {dgettext("ui", "退出工作区")}
          </.button>
        </div>
      </.settings_section>

      <.confirm_dialog
        id="slug-dialog"
        show={@pending_slug != nil}
        title={dgettext("ui", "修改工作区地址？")}
        confirm_label={dgettext("ui", "修改地址")}
        on_confirm="confirm_slug"
        confirm_value={%{slug: @pending_slug}}
        on_cancel={JS.push("cancel_slug")}
        danger
      >
        {dgettext("ui", "修改后 /w/%{slug} 的所有链接将失效。", slug: @current_scope.workspace.slug)}
      </.confirm_dialog>

      <.confirm_dialog
        id="leave-dialog"
        show={@confirm_leave?}
        title={dgettext("ui", "退出 %{workspace}？", workspace: @current_scope.workspace.name)}
        confirm_label={dgettext("ui", "退出工作区")}
        on_confirm="leave"
        on_cancel={JS.push("cancel_leave")}
        danger
      >
        {dgettext("ui", "之后需要重新被邀请才能加入；你在本工作区的 Token 将被吊销，名下 Agent 将被停用。")}
      </.confirm_dialog>
    </.settings_page>
    """
  end
end

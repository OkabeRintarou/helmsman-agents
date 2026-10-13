defmodule HelmsmanWeb.ProjectLive.Index do
  @moduledoc """
  Projects page `/w/:slug/projects` (design D4, spec web-projects): project cards
  ordered by key, the 显示已归档 switch (`?archived=1`) and the 新建项目 panel
  (`?panel=new-project`, admins). Cards reload on `{:projects_changed}` and
  `{:local_repositories_changed}` (the local repository chip's status), which the shell
  forwards from the workspace topic.
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.{Policy, Projects}
  alias HelmsmanWeb.{FormErrors, GitHubComponents, LocalRepositoryComponents, TaskComponents, Url}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: dgettext("ui", "项目"),
       can_create?: Policy.authorize(scope, :create_project) == :ok,
       archived?: false,
       projects: [],
       form: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    archived? = params["archived"] == "1"
    open? = params["panel"] == "new-project" and socket.assigns.can_create?

    form =
      cond do
        not open? -> nil
        socket.assigns.form -> socket.assigns.form
        true -> %{params: %{"key" => "", "name" => "", "description" => ""}, errors: %{}}
      end

    {:noreply,
     socket
     |> assign(archived?: archived?, uri: relative(uri), form: form)
     |> load()}
  end

  defp relative(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    if query, do: "#{path}?#{query}", else: path
  end

  defp load(socket) do
    {:ok, projects} =
      Projects.list(socket.assigns.current_scope, include_archived: socket.assigns.archived?)

    assign(socket, :projects, projects)
  end

  @impl true
  def handle_event("change", %{"project" => params}, socket) do
    params = params |> Map.take(~w(key name description)) |> Map.update("key", "", &upcase/1)
    {:noreply, assign(socket, :form, %{socket.assigns.form | params: params})}
  end

  def handle_event("create", %{"project" => params}, socket) do
    params = params |> Map.take(~w(key name description)) |> Map.update("key", "", &upcase/1)

    case Projects.create(socket.assigns.current_scope, params) do
      {:ok, project} ->
        slug = socket.assigns.current_scope.workspace.slug
        {:noreply, push_navigate(socket, to: "/w/#{slug}/p/#{project.key}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, %{params: params, errors: FormErrors.messages(changeset)})}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, dgettext("ui", "没有权限执行此操作"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("ui", "操作失败，请稍后重试"))}
    end
  end

  defp upcase(key), do: key |> String.trim() |> String.upcase()

  @impl true
  def handle_info(message, socket)
      when message in [{:projects_changed}, {:local_repositories_changed}],
      do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    slug = assigns.current_scope.workspace.slug

    assigns =
      assign(assigns,
        slug: slug,
        toggle_path:
          if(assigns.archived?,
            do: Url.drop_params(assigns.uri, ["archived"]),
            else: Url.put_params(assigns.uri, %{archived: "1"})
          ),
        new_path: Url.put_params(assigns.uri, %{panel: "new-project"}),
        close_path: Url.drop_params(assigns.uri, ["panel"])
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "项目")}>
          <:actions>
            <.button
              :if={@can_create?}
              id="new-project-button"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_path}
            >
              {dgettext("ui", "新建项目")}
            </.button>
          </:actions>
        </.page_header>
      </:header>
      <div class="flex items-center justify-end px-4 py-2">
        <.link
          id="show-archived"
          patch={@toggle_path}
          role="switch"
          aria-checked={to_string(@archived?)}
          class="inline-flex items-center gap-2 rounded-field px-2 py-1 text-label text-fg-muted hover:bg-hover hover:text-fg"
        >
          <span class={[
            "relative inline-flex h-4 w-7 items-center rounded-full border",
            if(@archived?, do: "border-brand bg-brand", else: "border-border-strong bg-surface")
          ]}>
            <span class={[
              "absolute size-3 rounded-full",
              if(@archived?, do: "left-3.5 bg-on-brand", else: "left-0.5 bg-fg-subtle")
            ]} />
          </span>
          {dgettext("ui", "显示已归档")}
        </.link>
      </div>
      <ul
        :if={@projects != []}
        id="projects"
        class="grid grid-cols-1 gap-3 px-4 pb-6 sm:grid-cols-2 xl:grid-cols-3"
      >
        <li :for={project <- @projects} id={"project-#{project.key}"}>
          <.link
            navigate={"/w/#{@slug}/p/#{project.key}"}
            class="flex h-full flex-col gap-2 rounded-box border border-border bg-surface p-4 hover:border-border-strong hover:bg-hover"
          >
            <span class="flex items-center gap-2">
              <span class="font-mono text-label text-fg-muted">{project.key}</span>
              <.badge :if={project.archived_at} data-archived>{dgettext("ui", "已归档")}</.badge>
            </span>
            <span class="truncate text-title font-medium text-fg">{project.name}</span>
            <span
              :if={(project.description || "") != ""}
              class="line-clamp-2 text-body text-fg-muted"
              data-description
            >
              {TaskComponents.excerpt(project.description, 140)}
            </span>
            <GitHubComponents.repo_chip
              :if={project.repository}
              id={"project-#{project.key}-repository"}
              repository={project.repository}
              link={false}
            />
            <LocalRepositoryComponents.local_repo_chip
              :if={project.local_repository}
              id={"project-#{project.key}-local-repository"}
              repository={project.local_repository}
            />
            <span class="mt-auto text-caption text-fg-subtle" data-count>
              {dngettext("ui", "%{count} 个任务", "%{count} 个任务", project.task_seq,
                count: project.task_seq
              )}
            </span>
          </.link>
        </li>
      </ul>
      <.empty_state
        :if={@projects == []}
        icon="lucide-folder"
        title={dgettext("ui", "还没有项目")}
        description={!@can_create? && dgettext("ui", "请联系管理员创建项目")}
      >
        <:action :if={@can_create?}>
          <.button variant="primary" icon="lucide-plus" patch={@new_path}>
            {dgettext("ui", "新建项目")}
          </.button>
        </:action>
      </.empty_state>

      <.side_panel
        id="new-project"
        show={@form != nil}
        title={dgettext("ui", "新建项目")}
        dirty={@form != nil and Enum.any?(Map.values(@form.params), &(&1 != ""))}
        patch_on_close={@close_path}
      >
        <.form
          for={%{}}
          as={:project}
          id="new-project-form"
          phx-change="change"
          phx-submit="create"
          class="flex flex-col gap-4"
        >
          <.input
            id="new-project-key"
            name="project[key]"
            label="Key"
            value={@form.params["key"]}
            help={dgettext("ui", "大写字母开头，2–10 位大写字母或数字，创建后不能修改")}
            errors={Map.get(@form.errors, :key, [])}
            autocomplete="off"
            class="font-mono uppercase"
          />
          <.input
            id="new-project-name"
            name="project[name]"
            label={dgettext("ui", "名称")}
            value={@form.params["name"]}
            errors={Map.get(@form.errors, :name, [])}
            autocomplete="off"
          />
          <.input
            type="textarea"
            id="new-project-description"
            name="project[description]"
            label={dgettext("ui", "描述（可选）")}
            value={@form.params["description"]}
            errors={Map.get(@form.errors, :description, [])}
            rows="4"
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button type="submit" form="new-project-form" variant="primary">
              {dgettext("ui", "创建")}
            </.button>
          </div>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end
end

defmodule HelmsmanWeb.TaskLive.Index do
  @moduledoc """
  A project's task list `/w/:slug/p/:key` (design D5, spec web-tasks): filter bar
  synced to the URL, a stream-backed table paged by 加载更多, live updates from
  `project:<id>`, and the project menu (edit, archive, restore; admins).

  Live updates never reload the table: a summary that passes the current filters is
  moved to the top, one that does not is removed (`HelmsmanWeb.TaskLive.Filter`). With a
  search text (`q`, add-search-query-ui D2) that cannot be decided in memory, so the
  loaded rows are read again instead, at most once a second.

  Rows carry `working`, the agents with a run in progress on the task (add-agents-runs-ui
  D15, R5), read once per loaded page. A run change of a loaded task (`workspace:<id>:runs`)
  re-reads only those tasks, coalesced by `HelmsmanWeb.Throttle`, and re-inserts the rows
  whose agents changed; runs of tasks that are not loaded are ignored.

  The header shows the bound GitHub repository, and owners / admins edit it with the
  merge settings in the 仓库与合并 panel (`?panel=project-github`, add-github-ui D6, D7;
  state in `HelmsmanWeb.ProjectGitHubForm`). Branch suggestions and the save (which checks
  the branch on GitHub) run with `start_async/3`; closing the panel cancels the save.

  A project bound to a local repository shows it in the header instead, and the panel's
  local mode saves with `Helmsman.Projects.bind_local_repository/4` synchronously (it
  only touches the database; add-local-repositories-ui D5, D6). `{:local_repositories_changed}`
  re-reads the project (the chip's status) and the panel's local options.
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.{Events, GitHub, Policy, Projects, Tasks}

  alias HelmsmanWeb.{
    CollabComponents,
    Filters,
    FormErrors,
    GitHubComponents,
    LocalRepositoryComponents,
    ProjectGitHubForm,
    RunData,
    TaskComponents,
    TaskData,
    Throttle,
    Url
  }

  alias HelmsmanWeb.TaskLive.Filter

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    scope = socket.assigns.current_scope

    project =
      case Projects.get(scope, key) do
        {:ok, project} -> project
        {:error, :not_found} -> raise HelmsmanWeb.NotFoundError
      end

    agents = TaskData.agent_info(scope)

    if connected?(socket) do
      Events.subscribe(Events.topic(:project, project.id))
      Events.subscribe(Events.topic(:workspace_runs, scope.workspace.id))
    end

    {:ok,
     socket
     |> stream_configure(:tasks, dom_id: &"task-#{&1.id}")
     |> stream(:tasks, [])
     |> assign(
       project: project,
       page_title: project.name,
       filters: nil,
       search_error: nil,
       label_options: TaskData.labels(scope, project.key),
       agents: agents,
       assignable: TaskData.assignable(scope, agents),
       can_manage?: Policy.authorize(scope, :update_project) == :ok,
       can_github?: Policy.authorize(scope, :manage_github) == :ok,
       github: nil,
       shown: MapSet.new(),
       working: %{},
       working_pending: MapSet.new(),
       cursor: nil,
       has_more: false,
       panel: nil,
       edit: nil
     )}
  end

  @impl true
  def handle_params(%{"key" => key} = params, uri, socket) do
    project = socket.assigns.project

    if key != project.key do
      {:noreply, push_navigate(socket, to: canonical(uri, key, project.key), replace: true)}
    else
      filters = Filters.parse(params, Filter.schema())
      socket = if filters != socket.assigns.filters, do: load(socket, filters), else: socket
      {:noreply, socket |> assign(:uri, relative(uri)) |> put_panel(params["panel"])}
    end
  end

  defp canonical(uri, key, canonical_key) do
    %URI{path: path, query: query} = URI.parse(uri)
    path = String.replace_suffix(path, "/p/#{key}", "/p/#{canonical_key}")
    if query, do: "#{path}?#{query}", else: path
  end

  defp relative(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    if query, do: "#{path}?#{query}", else: path
  end

  defp put_panel(socket, "edit-project") do
    %{project: project, can_manage?: can?} = socket.assigns

    cond do
      not can? ->
        close_github(socket)

      socket.assigns.panel == "edit-project" ->
        socket

      true ->
        socket
        |> close_github()
        |> assign(
          panel: "edit-project",
          edit: %{
            params: %{"name" => project.name, "description" => project.description || ""},
            errors: %{}
          }
        )
    end
  end

  defp put_panel(socket, "project-github") do
    %{current_scope: scope, project: project, can_github?: can?} = socket.assigns

    cond do
      not can? ->
        close_github(socket)

      socket.assigns.panel == "project-github" ->
        socket

      true ->
        form = ProjectGitHubForm.new(scope, project)

        socket
        |> assign(panel: "project-github", edit: nil, github: form)
        |> load_branches()
    end
  end

  defp put_panel(socket, _panel), do: close_github(socket)

  defp close_github(socket) do
    socket
    |> cancel_async(:project_github_save)
    |> cancel_async(:project_github_branches)
    |> assign(panel: nil, edit: nil, github: nil)
  end

  # Branch suggestions of the selected repository; a failure shows none.
  defp load_branches(%{assigns: %{github: %{params: %{repository_id: id}}}} = socket)
       when is_integer(id) do
    scope = socket.assigns.current_scope
    start_async(socket, :project_github_branches, fn -> {id, GitHub.list_branches(scope, id)} end)
  end

  defp load_branches(socket), do: cancel_async(socket, :project_github_branches)

  defp load(socket, filters) do
    %{current_scope: scope, project: project} = socket.assigns
    opts = Filter.domain_opts(filters)

    case TaskData.page(scope, project.key, opts, nil) do
      {:ok, rows, has_more, cursor} ->
        socket
        |> assign(:search_error, nil)
        |> show_page(filters, rows, has_more, cursor)

      # The rows shown stay, but they belong to the previous filters: paging stops until
      # the text is corrected (code-review-2 P2-3).
      {:error, {:invalid_query, _}} ->
        assign(socket, filters: filters, search_error: search_too_long(), has_more: false)
    end
  end

  @max_search 200
  @search_reload_ms 1000

  defp search_too_long, do: dgettext("ui", "最多 %{n} 个字符", n: @max_search)

  defp show_page(socket, filters, rows, has_more, cursor) do
    scope = socket.assigns.current_scope
    summaries = Enum.map(rows, &Tasks.summary/1)
    working = read_working(scope, summaries)
    summaries = Enum.map(summaries, &with_working(&1, working))

    socket
    |> assign(
      working: working,
      filters: filters,
      has_more: has_more,
      cursor: cursor,
      shown: MapSet.new(summaries, & &1.id)
    )
    |> merge_labels(summaries)
    |> stream(:tasks, summaries, reset: true)
  end

  @impl true
  def handle_event("load_more", _params, socket), do: {:noreply, load_next(socket)}

  # The search box (add-search-query-ui D2): the text goes to the URL; too long a text
  # keeps the list and says so.
  def handle_event("search", params, socket) do
    q = String.trim(params["q"] || "")

    if String.length(q) > @max_search do
      {:noreply, assign(socket, :search_error, search_too_long())}
    else
      filters = socket.assigns.filters || %{}
      filters = if q == "", do: Map.delete(filters, :q), else: Map.put(filters, :q, q)
      base = "/w/#{socket.assigns.current_scope.workspace.slug}/p/#{socket.assigns.project.key}"

      {:noreply,
       socket |> assign(:search_error, nil) |> push_patch(to: Filters.path(base, filters))}
    end
  end

  def handle_event("edit_project_change", %{"project" => params}, socket) do
    edit = %{socket.assigns.edit | params: Map.take(params, ~w(name description))}
    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("edit_project_save", %{"project" => params}, socket) do
    %{current_scope: scope, project: project} = socket.assigns
    params = Map.take(params, ~w(name description))

    case Projects.update(scope, project.key, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project, page_title: project.name)
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :edit, %{params: params, errors: FormErrors.messages(changeset)})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, failure(reason))}
    end
  end

  def handle_event("project_github_" <> event, params, %{assigns: %{github: %{}}} = socket),
    do: github_event(event, params, socket)

  def handle_event("project_github_" <> _event, _params, socket), do: {:noreply, socket}

  def handle_event("archive", _params, socket),
    do: set_archived(socket, &Projects.archive/2, dgettext("ui", "项目已归档"))

  def handle_event("unarchive", _params, socket),
    do: set_archived(socket, &Projects.unarchive/2, dgettext("ui", "项目已恢复"))

  defp load_next(socket) do
    %{current_scope: scope, project: project, filters: filters} = socket.assigns
    opts = Filter.domain_opts(filters)

    case TaskData.page(scope, project.key, opts, socket.assigns.cursor) do
      {:ok, rows, has_more, cursor} -> append_page(socket, rows, has_more, cursor)
      {:error, _} -> assign(socket, has_more: false)
    end
  end

  defp append_page(socket, rows, has_more, cursor) do
    scope = socket.assigns.current_scope

    summaries = Enum.map(rows, &Tasks.summary/1)
    working = read_working(scope, summaries)
    summaries = Enum.map(summaries, &with_working(&1, working))
    socket = assign(socket, :working, Map.merge(socket.assigns.working, working))

    socket =
      Enum.reduce(summaries, socket, fn summary, socket ->
        stream_insert(socket, :tasks, summary, at: -1)
      end)

    socket
    |> assign(
      has_more: has_more,
      cursor: cursor,
      shown: Enum.reduce(summaries, socket.assigns.shown, &MapSet.put(&2, &1.id))
    )
    |> merge_labels(summaries)
  end

  defp set_archived(socket, fun, message) do
    case fun.(socket.assigns.current_scope, socket.assigns.project.key) do
      {:ok, project} ->
        {:noreply, socket |> assign(:project, project) |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, failure(reason))}
    end
  end

  defp github_event(_event, _params, %{assigns: %{github: %{saving?: true}}} = socket),
    do: {:noreply, socket}

  defp github_event("repository", %{"id" => id}, socket) do
    id =
      case Integer.parse(to_string(id)) do
        {id, ""} -> id
        _ -> nil
      end

    form = ProjectGitHubForm.select_repository(socket.assigns.github, id)
    {:noreply, socket |> assign(:github, form) |> branches_if_moved(socket.assigns.github)}
  end

  defp github_event("mode", %{"mode" => mode}, socket) when mode in ["github", "local"] do
    form = ProjectGitHubForm.set_mode(socket.assigns.github, String.to_existing_atom(mode))
    {:noreply, socket |> assign(:github, form) |> branches_if_moved(socket.assigns.github)}
  end

  defp github_event("local_repository", %{"id" => id}, socket) do
    id =
      case Integer.parse(to_string(id)) do
        {id, ""} -> id
        _ -> nil
      end

    {:noreply, assign(socket, :github, ProjectGitHubForm.select_local(socket.assigns.github, id))}
  end

  defp github_event("change", %{"project_github" => params}, socket) do
    form = ProjectGitHubForm.change(socket.assigns.github, params)
    {:noreply, socket |> assign(:github, form) |> branches_if_moved(socket.assigns.github)}
  end

  # The submit carries the latest fields: a debounced change may not have been sent.
  defp github_event("save", params, %{assigns: %{github: %{mode: :local}}} = socket) do
    form = ProjectGitHubForm.change(socket.assigns.github, Map.get(params, "project_github", %{}))

    if ProjectGitHubForm.dirty?(form) do
      {id, opts} = ProjectGitHubForm.local_binding(form)
      scope = socket.assigns.current_scope

      case Projects.bind_local_repository(scope, form.key, id, opts) do
        {:ok, project} ->
          {:noreply,
           socket
           |> assign(project: project, page_title: project.name, panel: nil, github: nil)
           |> put_flash(:info, dgettext("ui", "已保存仓库设置"))
           |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

        {:error, reason} ->
          {:noreply, socket |> assign(:github, form) |> local_save_failed(reason)}
      end
    else
      {:noreply, assign(socket, :github, form)}
    end
  end

  defp github_event("save", params, socket) do
    form = ProjectGitHubForm.change(socket.assigns.github, Map.get(params, "project_github", %{}))
    socket = socket |> assign(:github, form) |> branches_if_moved(socket.assigns.github)
    attrs = ProjectGitHubForm.attrs(form)

    if attrs == %{} do
      {:noreply, socket}
    else
      scope = socket.assigns.current_scope
      key = form.key

      {:noreply,
       socket
       |> assign(:github, ProjectGitHubForm.saving(form))
       |> start_async(:project_github_save, fn ->
         Projects.update_github_settings(scope, key, attrs)
       end)}
    end
  end

  defp github_event(_event, _params, socket), do: {:noreply, socket}

  defp branches_if_moved(socket, old) do
    if socket.assigns.github.params.repository_id != old.params.repository_id,
      do: load_branches(socket),
      else: socket
  end

  @impl true
  def handle_async(:project_github_branches, {:ok, {id, {:ok, names}}}, socket) do
    case socket.assigns.github do
      %{params: %{repository_id: ^id}} = form ->
        {:noreply, assign(socket, :github, %{form | branches: names})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async(:project_github_branches, _result, socket), do: {:noreply, socket}

  def handle_async(
        :project_github_save,
        result,
        %{assigns: %{github: %{saving?: true}}} = socket
      ),
      do: {:noreply, saved(socket, result)}

  def handle_async(:project_github_save, _result, socket), do: {:noreply, socket}

  defp saved(socket, {:ok, {:ok, project}}) do
    socket
    |> assign(project: project, page_title: project.name, panel: nil, github: nil)
    |> put_flash(:info, dgettext("ui", "已保存仓库与合并设置"))
    |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))
  end

  defp saved(socket, {:ok, {:error, reason}}), do: save_failed(socket, reason)

  defp saved(socket, {:exit, _reason}), do: save_failed(socket, :exit)

  defp save_failed(socket, reason) do
    %{current_scope: scope, github: form, project: project} = socket.assigns

    fresh =
      if reason in [:stale, :not_found] do
        Projects.get(scope, project.key)
      end

    case {reason, fresh} do
      {_reason, {:error, _}} ->
        close_with_error(socket, dgettext("ui", "项目不存在"))

      {:stale, {:ok, project}} ->
        {:form, form, _reload?} = ProjectGitHubForm.errors(form, :stale)

        form =
          form |> ProjectGitHubForm.stale(project) |> ProjectGitHubForm.reload_repositories(scope)

        socket
        |> assign(project: project, page_title: project.name, github: form)
        |> load_branches()

      _ ->
        case ProjectGitHubForm.errors(form, reason) do
          {:form, form, true} ->
            assign(socket, :github, ProjectGitHubForm.reload_repositories(form, scope))

          {:form, form, false} ->
            assign(socket, :github, form)

          {:close, message} ->
            close_with_error(socket, message)
        end
    end
  end

  # D5: the save's errors in the local mode.
  defp local_save_failed(socket, reason) when reason in [:repository_already_bound, :not_found] do
    %{current_scope: scope, github: form, project: project} = socket.assigns

    case {reason, Projects.get(scope, project.key)} do
      {_reason, {:error, _}} ->
        close_with_error(socket, dgettext("ui", "项目不存在"))

      {:repository_already_bound, {:ok, project}} ->
        socket
        |> assign(
          project: project,
          page_title: project.name,
          github: ProjectGitHubForm.already_bound(form, project)
        )
        |> load_branches()

      {:not_found, {:ok, project}} ->
        {:form, form, _reload?} = ProjectGitHubForm.errors(form, :not_found)
        form = %{form | current_local: project.local_repository}
        assign(socket, project: project, github: ProjectGitHubForm.reload_locals(form, scope))
    end
  end

  defp local_save_failed(socket, reason) do
    case ProjectGitHubForm.errors(socket.assigns.github, reason) do
      {:form, form, _reload?} -> assign(socket, :github, form)
      {:close, message} -> close_with_error(socket, message)
    end
  end

  defp close_with_error(socket, message) do
    socket
    |> assign(panel: nil, github: nil)
    |> put_flash(:error, message)
    |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))
  end

  defp failure(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp failure(_reason), do: dgettext("ui", "操作失败，请稍后重试")

  @impl true
  def handle_info({event, %{project_key: _} = summary}, socket)
      when event in [:task_created, :task_updated] do
    socket = merge_labels(socket, [summary])

    cond do
      Filter.search?(socket.assigns.filters) ->
        {:noreply, Throttle.schedule(socket, :reload_search, @search_reload_ms)}

      Filter.match?(summary, socket.assigns.filters) ->
        {:noreply, put_matching(socket, summary)}

      true ->
        {:noreply, drop_row(socket, summary)}
    end
  end

  # With a search text the rows already shown are read again (add-search-query-ui D2):
  # as many as are loaded, at most 200; the rest comes with 加载更多.
  def handle_info(:reload_search, socket),
    do: {:noreply, socket |> Throttle.done(:reload_search) |> reread_rows()}

  # The shell reloaded the identity appearance (add-actor-avatars D7); streamed rows are
  # only rendered when inserted, so the rows shown are read again.
  def handle_info(message, socket)
      when message in [{:avatars_changed}, {:agents_changed}, {:members_changed}],
      do: {:noreply, Throttle.schedule(socket, :reload_rows)}

  def handle_info({:squad, _id}, socket), do: {:noreply, Throttle.schedule(socket, :reload_rows)}

  def handle_info(:reload_rows, socket),
    do: {:noreply, socket |> Throttle.done(:reload_rows) |> reread_rows()}

  def handle_info({:run_updated, %{task: ident}}, socket) when is_binary(ident) do
    if MapSet.member?(socket.assigns.shown, ident) do
      pending = MapSet.put(socket.assigns.working_pending, ident)

      {:noreply,
       socket |> assign(:working_pending, pending) |> Throttle.schedule(:reload_working)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_working, socket) do
    socket = Throttle.done(socket, :reload_working)
    idents = socket.assigns.working_pending |> MapSet.intersection(socket.assigns.shown)
    socket = assign(socket, :working_pending, MapSet.new())
    {:noreply, refresh_working(socket, MapSet.to_list(idents))}
  end

  def handle_info({:projects_changed}, socket) do
    case Projects.get(socket.assigns.current_scope, socket.assigns.project.key) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project, page_title: project.name)
         |> rebase_github(project)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:local_repositories_changed}, socket) do
    scope = socket.assigns.current_scope

    case Projects.get(scope, socket.assigns.project.key) do
      {:ok, project} ->
        socket = assign(socket, :project, project)

        case socket.assigns.github do
          %{} = form ->
            form = ProjectGitHubForm.reload_locals(form, scope)
            {:noreply, assign(socket, :github, %{form | current_local: project.local_repository})}

          nil ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:github_changed}, %{assigns: %{github: %{} = form}} = socket) do
    form = ProjectGitHubForm.reload_repositories(form, socket.assigns.current_scope)
    {:noreply, assign(socket, :github, form)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # While saving the panel keeps its state: the save's result decides (D6).
  defp rebase_github(%{assigns: %{github: %{saving?: false} = form}} = socket, project) do
    socket
    |> assign(:github, ProjectGitHubForm.rebase(form, project))
    |> branches_if_moved(form)
  end

  defp rebase_github(socket, _project), do: socket

  # The agents working on each task of `summaries` (R5): one query.
  defp read_working(_scope, []), do: %{}

  defp read_working(scope, summaries) do
    case RunData.active_agents(scope, Enum.map(summaries, & &1.id)) do
      {:ok, working} -> working
      {:error, _} -> %{}
    end
  end

  defp put_working(socket, ident, fresh),
    do: assign(socket, :working, socket.assigns.working |> Map.delete(ident) |> Map.merge(fresh))

  # A row that leaves the list keeps no run state: it is read again if it comes back.
  defp forget_working(socket, ident) do
    assign(socket,
      working: Map.delete(socket.assigns.working, ident),
      working_pending: MapSet.delete(socket.assigns.working_pending, ident)
    )
  end

  defp with_working(summary, working),
    do: Map.put(summary, :working, Map.get(working, summary.id, []))

  # Re-reads the agents of `idents` and re-inserts the rows whose agents changed.
  defp refresh_working(socket, []), do: socket

  defp refresh_working(socket, idents) do
    %{current_scope: scope, working: working} = socket.assigns

    fresh =
      case RunData.active_agents(scope, idents) do
        {:ok, map} -> map
        {:error, _} -> Map.take(working, idents)
      end

    changed = Enum.filter(idents, &(Map.get(fresh, &1, []) != Map.get(working, &1, [])))
    working = working |> Map.drop(idents) |> Map.merge(fresh)
    socket = assign(socket, :working, working)

    Enum.reduce(changed, socket, fn ident, socket ->
      case Tasks.get(scope, ident) do
        {:ok, task} ->
          stream_insert(socket, :tasks, with_working(Tasks.summary(task), working))

        {:error, _} ->
          socket
      end
    end)
  end

  # Every loaded row left the filter but more may match after the cursor: load the
  # next page instead of reporting an empty list.
  # The first `count` rows in pages of `TaskData.page/4` (the domain reads at most 200 at
  # a time), with whether more follow and the cursor of the last (code-review-1 P2-1).
  defp reread_rows(%{assigns: %{filters: nil}} = socket), do: socket

  defp reread_rows(socket) do
    %{current_scope: scope, project: project, filters: filters} = socket.assigns
    count = max(MapSet.size(socket.assigns.shown), TaskData.page_size())

    case read_rows(scope, project.key, Filter.domain_opts(filters), count) do
      {:ok, rows, has_more, cursor} -> show_page(socket, filters, rows, has_more, cursor)
      {:error, _} -> socket
    end
  end

  defp read_rows(scope, key, opts, count, cursor \\ nil, acc \\ []) do
    with {:ok, rows, has_more, next} <- TaskData.page(scope, key, opts, cursor) do
      acc = acc ++ rows

      cond do
        length(acc) > count ->
          taken = Enum.take(acc, count)
          last = List.last(taken)
          {:ok, taken, true, {last.updated_at, last.id}}

        length(acc) == count or not has_more ->
          {:ok, acc, has_more, next}

        true ->
          read_rows(scope, key, opts, count, next, acc)
      end
    end
  end

  defp put_matching(socket, summary) do
    # A task entering the list may already have runs in progress: its runs were not
    # followed while it was out, so they are read now (code-review-4).
    socket =
      if MapSet.member?(socket.assigns.shown, summary.id),
        do: socket,
        else:
          put_working(socket, summary.id, read_working(socket.assigns.current_scope, [summary]))

    summary = with_working(summary, socket.assigns.working)

    socket
    |> stream_delete(:tasks, summary)
    |> stream_insert(:tasks, summary, at: 0)
    |> assign(:shown, MapSet.put(socket.assigns.shown, summary.id))
  end

  defp drop_row(socket, summary) do
    socket
    |> stream_delete(:tasks, summary)
    |> forget_working(summary.id)
    |> assign(:shown, MapSet.delete(socket.assigns.shown, summary.id))
    |> refill()
  end

  defp refill(%{assigns: %{has_more: true}} = socket) do
    if MapSet.size(socket.assigns.shown) == 0, do: load_next(socket), else: socket
  end

  defp refill(socket), do: socket

  defp merge_labels(socket, summaries) do
    labels =
      summaries
      |> Enum.flat_map(&(&1.labels || []))
      |> Enum.concat(socket.assigns.label_options)
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket, :label_options, labels)
  end

  defp working_label([name]), do: dgettext("ui", "%{name} 正在处理", name: name)

  defp working_label([name | rest]),
    do: dgettext("ui", "%{name} 等 %{count} 个正在处理", name: name, count: length(rest) + 1)

  @impl true
  def render(assigns) do
    slug = assigns.current_scope.workspace.slug
    base = "/w/#{slug}/p/#{assigns.project.key}"

    assigns =
      assign(assigns,
        slug: slug,
        base: base,
        archived?: assigns.project.archived_at != nil,
        dimensions: dimensions(assigns),
        view: Filter.current_view(assigns.filters),
        new_task_path: Url.put_params(assigns.uri, %{panel: "new"}),
        close_path: Url.drop_params(assigns.uri, ["panel"]),
        empty?: MapSet.size(assigns.shown) == 0 and not assigns.has_more
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@project.name}>
          <:crumb navigate={"/w/#{@slug}/projects"}>{dgettext("ui", "项目")}</:crumb>
          <:actions>
            <.dropdown
              :if={@can_manage?}
              id="project-menu"
              label={dgettext("ui", "项目菜单")}
              align={:end}
              items={project_menu(@archived?, @uri, @can_github?)}
              trigger_class="h-8 w-8 justify-center"
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
            <.button
              :if={@shell.can_create_task?}
              id="project-new-task"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_task_path}
              disabled_reason={if(@archived?, do: dgettext("ui", "项目已归档"))}
            >
              {dgettext("ui", "新建任务")}
            </.button>
          </:actions>
        </.page_header>
      </:header>
      <div :if={@project.repository} id="project-repository" class="flex px-4 pt-3">
        <GitHubComponents.repo_chip
          id="project-repository-chip"
          repository={@project.repository}
          branch={@project.effective_base_branch}
        />
      </div>
      <div :if={@project.local_repository} id="project-local-repository" class="flex px-4 pt-3">
        <LocalRepositoryComponents.local_repo_chip
          id="project-local-repository-chip"
          repository={@project.local_repository}
          branch={@project.effective_base_branch}
        />
      </div>
      <div
        :if={@archived?}
        id="project-archived-banner"
        role="status"
        class="mx-4 mt-3 flex items-center gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-archive" class="size-4" />{dgettext("ui", "此项目已归档")}
      </div>
      <.filter_bar
        id="task-filters"
        path={@base}
        filters={@filters}
        dimensions={@dimensions}
      >
        <:views>
          <.link
            :for={{id, label, statuses} <- Filter.views()}
            id={"task-view-#{id}"}
            patch={Filters.path(@base, Filter.apply_view(@filters, statuses))}
            aria-current={@view == id && "page"}
            class={[
              "inline-flex h-7 items-center rounded-field px-2 text-label",
              if(@view == id,
                do: "bg-selected font-medium text-fg",
                else: "text-fg-muted hover:bg-hover hover:text-fg"
              )
            ]}
          >
            {label}
          </.link>
        </:views>
      </.filter_bar>
      <p
        :if={@search_error}
        id="task-search-error"
        role="alert"
        class="-mt-1 px-4 pb-2 text-right text-caption text-danger-fg"
      >
        {@search_error}
      </p>
      <.data_table
        id="tasks"
        class={@empty? && "hidden"}
        rows={@streams.tasks}
        label={dgettext("ui", "%{project} 的任务", project: @project.name)}
        row_click={&JS.navigate("/w/#{@slug}/t/#{&1.id}")}
        row_version={&{&1.updated_at, &1[:working], &1[:blocked], &1[:progress]}}
        has_more={@has_more}
        load_more="load_more"
      >
        <:col :let={task} label={dgettext("ui", "状态")} class="w-10">
          <.status_icon status={task.status} />
        </:col>
        <:col :let={task} label="ID" class="w-24">
          <.task_id_link ident={task.id} workspace={@slug} status={task.status} />
        </:col>
        <:col :let={task} label={dgettext("ui", "标题")}>
          <span class="inline-flex min-w-0 items-center gap-1.5">
            <CollabComponents.epic_badge :if={task[:kind] == "epic"} kind="epic" />
            <span class="truncate text-fg">{task.title}</span>
            <CollabComponents.epic_progress
              :if={task[:kind] == "epic"}
              progress={task[:progress]}
              data-epic-progress
            />
            <.tooltip :if={task[:blocked]} text={dgettext("ui", "被阻塞")} class="flex-none">
              <.icon
                name="lucide-octagon-pause"
                class="size-3.5 text-warning"
                label={dgettext("ui", "被阻塞")}
                data-blocked
              />
            </.tooltip>
            <.icon
              :if={(task[:working] || []) != []}
              name="lucide-loader"
              class="size-3.5 flex-none text-brand motion-safe:animate-spin"
              label={working_label(task.working)}
              data-working
            />
            <.tooltip :if={task.open_question} text={dgettext("ui", "待回答")} class="flex-none">
              <.icon
                name="lucide-circle-question-mark"
                class="size-3.5 text-warning"
                label={dgettext("ui", "待回答")}
                data-open-question
              />
            </.tooltip>
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "标签")} secondary class="w-48">
          <span class="flex items-center gap-1 overflow-hidden">
            <button
              :for={label <- task.labels}
              type="button"
              data-label={label}
              class="rounded-badge bg-hover px-1.5 text-caption text-fg-muted hover:text-fg"
              phx-click={JS.patch(Filters.path(@base, Filters.put_single(@filters, :label, label)))}
            >
              {label}
            </button>
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "优先级")} secondary class="w-16">
          <.priority_icon priority={task.priority} />
        </:col>
        <:col :let={task} label={dgettext("ui", "执行方")} class="w-32">
          <span :if={task.assignee}>
            <TaskComponents.actor_ref
              actor={task.assignee}
              agents={@agents}
              appearance={@appearance}
              slug={@slug}
              compact
            />
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "更新")} secondary class="w-24">
          <.relative_time
            id={"task-#{task.id}-updated-#{:erlang.phash2(task.updated_at)}"}
            at={task.updated_at}
            class="text-caption text-fg-muted"
          />
        </:col>
      </.data_table>
      <.empty_state
        :if={@empty? and @filters != %{}}
        kind={:filtered}
        on_clear={JS.patch(@base)}
      />
      <.empty_state
        :if={@empty? and @filters == %{}}
        icon="lucide-list-todo"
        title={dgettext("ui", "还没有任务")}
      >
        <:action :if={@shell.can_create_task? and not @archived?}>
          <.button variant="primary" icon="lucide-plus" patch={@new_task_path}>
            {dgettext("ui", "新建任务")}
          </.button>
        </:action>
      </.empty_state>

      <.confirm_dialog
        :if={@can_manage?}
        id="archive-project-dialog"
        title={dgettext("ui", "归档项目 %{key}？", key: @project.key)}
        confirm_label={dgettext("ui", "归档")}
        on_confirm="archive"
      >
        {dgettext("ui", "归档后不能在其中新建任务，已有任务照常可读、可编辑、可迁移。")}
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="edit-project"
        show={@edit != nil}
        title={dgettext("ui", "编辑项目")}
        patch_on_close={@close_path}
      >
        <.form
          for={%{}}
          as={:project}
          id="edit-project-form"
          phx-change="edit_project_change"
          phx-submit="edit_project_save"
          class="flex flex-col gap-4"
        >
          <.input
            id="edit-project-key"
            name="project[key]"
            label="Key"
            value={@project.key}
            readonly
            help={dgettext("ui", "Key 创建后不能修改")}
            class="font-mono"
          />
          <.input
            id="edit-project-name"
            name="project[name]"
            label={dgettext("ui", "名称")}
            value={@edit.params["name"]}
            errors={Map.get(@edit.errors, :name, [])}
          />
          <.input
            type="textarea"
            id="edit-project-description"
            name="project[description]"
            label={dgettext("ui", "描述")}
            value={@edit.params["description"]}
            errors={Map.get(@edit.errors, :description, [])}
            rows="5"
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button type="submit" form="edit-project-form" variant="primary">
              {dgettext("ui", "保存")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <ProjectGitHubForm.panel
        :if={@github}
        form={@github}
        project={@project}
        slug={@slug}
        close_path={@close_path}
      />
    </Layouts.app>
    """
  end

  defp project_menu(archived?, uri, can_github?) do
    edit = %{
      id: "project-menu-edit",
      label: dgettext("ui", "编辑项目"),
      icon: "lucide-pencil",
      patch: Url.put_params(uri, %{panel: "edit-project"})
    }

    github = %{
      id: "project-menu-github",
      label: dgettext("ui", "仓库与合并"),
      icon: "lucide-git-branch",
      patch: Url.put_params(uri, %{panel: "project-github"})
    }

    items = if can_github?, do: [edit, github], else: [edit]

    if archived? do
      items ++
        [
          %{
            id: "project-menu-unarchive",
            label: dgettext("ui", "恢复项目"),
            icon: "lucide-archive-restore",
            on_select: "unarchive"
          }
        ]
    else
      items ++
        [
          %{
            id: "project-menu-archive",
            label: dgettext("ui", "归档项目"),
            icon: "lucide-archive",
            on_select: JS.exec("data-show", to: "#archive-project-dialog")
          }
        ]
    end
  end

  defp dimensions(assigns) do
    [
      %{
        key: :status,
        label: dgettext("ui", "状态"),
        options: Enum.map(Filter.statuses(), &{&1, TaskComponents.status_label(&1)})
      },
      %{
        key: :label,
        label: dgettext("ui", "标签"),
        single: true,
        options: Enum.map(assigns.label_options, &{&1, &1})
      },
      %{
        key: :assignee,
        label: dgettext("ui", "执行方"),
        single: true,
        options: [
          {"@none", dgettext("ui", "未指派")} | Enum.map(assigns.assignable, &{&1.name, &1.name})
        ]
      }
    ]
  end
end

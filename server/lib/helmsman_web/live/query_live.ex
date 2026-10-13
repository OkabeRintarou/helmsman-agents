defmodule HelmsmanWeb.QueryLive do
  @moduledoc """
  The BQL page `/w/:slug/query` (spec web-query, add-search-query-ui D3–D7): the editor
  (Ctrl/⌘+Enter runs), validation while typing with a one-line error preview, the field
  reference, example queries, the result table paged by 加载更多, and saved filters.

  The URL is the only source of the query: running patches `?bql=` (and keeps
  `?filter=<ID>` while a filter is open), and `handle_params/3` runs it — the same query
  is not run twice unless asked (运行 on an unchanged URL, 重新运行).

  An open filter is kept twice (D6): `filter`, the latest view (name, sharing, owner,
  permissions), and `base`, the version editing started from; 保存到 and the edit panel
  send `base.lock_version`, so a change by someone else is never overwritten. The shell
  forwards `{:filters_changed, _}`: an unrelated change refreshes `filter` only, a new
  version is loaded quietly when there is no local change and no open edit panel (else
  the header offers 载入最新), and a filter that disappeared is let go of while the
  editor and the results stay.

  The editor, the URL and saves always hold the user's own text (`BQL.to_string/1` is
  display-only and never replaces it).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.QueryComponents

  alias HelmsmanWeb.{FilterForm, QueryData, TaskData, Url}

  @page 50
  @max_results 10_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "查询"),
       can_save?: QueryData.can_save?(scope),
       fields: QueryData.fields(),
       agents: TaskData.agent_info(scope),
       bql: "",
       error: nil,
       result: nil,
       stale?: false,
       ran: nil,
       source: nil,
       filter: nil,
       base: nil,
       conflict: nil,
       panel: nil,
       form: nil,
       confirm_delete?: false,
       fields_open?: false,
       list_q: "",
       uri: nil
     )
     |> stream_configure(:tasks, dom_id: &"query-task-#{&1.id}")
     |> stream(:tasks, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    socket = assign(socket, :uri, if(query, do: "#{path}?#{query}", else: path))

    source = {blank(params["filter"]), blank(params["bql"])}

    socket =
      if source == socket.assigns.source,
        do: socket,
        else: socket |> assign(:source, source) |> apply_source(source)

    {:noreply, put_panel(socket, params["panel"])}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value) when is_binary(value), do: value
  defp blank(_value), do: nil

  ## Query source (the URL)

  defp apply_source(socket, {nil, nil}) do
    socket
    |> assign(
      filter: nil,
      base: nil,
      conflict: nil,
      bql: "",
      error: nil,
      result: nil,
      stale?: false,
      ran: nil
    )
    |> stream(:tasks, [], reset: true)
  end

  defp apply_source(socket, {nil, bql}) do
    socket
    |> assign(filter: nil, base: nil, conflict: nil, bql: bql)
    |> run_once(bql)
  end

  defp apply_source(socket, {id, bql}) do
    case socket.assigns.base do
      %{} = base when id == base.id ->
        bql = bql || base.bql
        socket |> assign(:bql, bql) |> run_once(bql)

      _ ->
        open_filter(socket, id, bql)
    end
  end

  defp open_filter(socket, id, bql) do
    case QueryData.get_filter(socket.assigns.current_scope, id) do
      {:ok, filter} ->
        bql = bql || filter.bql

        socket
        |> assign(filter: filter, base: base(filter), conflict: nil, bql: bql)
        |> assign(:page_title, filter.name)
        |> run_once(bql)

      {:error, _} ->
        socket
        |> assign(filter: nil, base: nil, conflict: nil, bql: bql || "")
        |> assign(:page_title, dgettext("ui", "查询"))
        |> put_flash(:error, dgettext("ui", "筛选器不存在或你无权查看"))
        |> patch_source({nil, bql})
        |> then(&if(bql, do: run_once(&1, bql), else: &1))
    end
  end

  # `id` as in the URL (a string), so it compares with the source.
  defp base(filter) do
    filter
    |> Map.take([:bql, :name, :visibility, :lock_version])
    |> Map.put(:id, to_string(filter.id))
  end

  # Patches the URL to `source` without running it again.
  defp patch_source(socket, source, extra \\ %{}) do
    socket
    |> assign(:source, source)
    |> patch_to(source, extra)
  end

  defp source_for(socket, bql) do
    case socket.assigns.base do
      nil -> {nil, blank(bql)}
      %{id: id, bql: ^bql} -> {id, nil}
      %{id: id} -> {id, bql}
    end
  end

  ## Running

  defp run_once(socket, bql) do
    if bql == socket.assigns.ran, do: socket, else: run(socket, bql)
  end

  defp run(socket, bql) do
    socket = assign(socket, :ran, bql)

    with :ok <- parse(socket, bql),
         {:ok, %{tasks: tasks, total: total, order: order}} <-
           QueryData.query(socket.assigns.current_scope, bql, limit: @page, offset: 0) do
      socket
      |> assign(
        result: %{bql: bql, total: total, order: order, loaded: length(tasks)},
        error: nil,
        stale?: false
      )
      |> stream(:tasks, tasks, reset: true)
    else
      {:error, reason} -> failed(socket, bql, reason)
    end
  end

  defp parse(_socket, bql) do
    case QueryData.parse(bql) do
      :ok -> :ok
      {:error, error} -> {:error, {:invalid_bql, error}}
    end
  end

  defp failed(socket, bql, reason) do
    assign(socket, error: run_error(bql, reason), stale?: socket.assigns.result != nil)
  end

  defp run_error(bql, {:invalid_bql, %{message: message, position: position}}),
    do: %{message: message, position: position, bql: bql}

  defp run_error(_bql, :query_timeout),
    do: %{message: dgettext("ui", "查询超时：请缩小范围（例如加上 project = KEY）")}

  defp run_error(_bql, :no_identity),
    do: %{message: dgettext("ui", "你在这个工作区还没有身份，不能运行查询")}

  defp run_error(_bql, :forbidden), do: %{message: dgettext("ui", "没有权限执行此操作")}
  defp run_error(_bql, _reason), do: %{message: dgettext("ui", "查询失败，请稍后重试")}

  # Pages always continue the query of the rows shown (`result.bql`), not the last one
  # tried: after a failed run the old rows stay, marked stale (code-review-1 P2-2).
  defp load_more(%{assigns: %{result: %{loaded: loaded, bql: bql} = result}} = socket) do
    case QueryData.query(socket.assigns.current_scope, bql,
           limit: @page,
           offset: loaded
         ) do
      {:ok, %{tasks: tasks, total: total}} ->
        socket = Enum.reduce(tasks, socket, &stream_insert(&2, :tasks, &1, at: -1))
        assign(socket, :result, %{result | total: total, loaded: loaded + length(tasks)})

      {:error, reason} ->
        failed(socket, bql, reason)
    end
  end

  defp load_more(socket), do: socket

  ## Panels

  defp put_panel(socket, "save-filter") do
    if socket.assigns.can_save? do
      form =
        case socket.assigns.form do
          %{mode: :create} = form -> form
          _ -> FilterForm.new(:create)
        end

      assign(socket, panel: :save, form: form)
    else
      close_panel(socket)
    end
  end

  defp put_panel(%{assigns: %{filter: %{} = filter}} = socket, "edit-filter") do
    scope = socket.assigns.current_scope

    if QueryData.can_edit?(scope, filter) do
      form =
        case socket.assigns.form do
          %{mode: :edit} = form ->
            form

          _ ->
            FilterForm.new(:edit, filter, QueryData.can_change_visibility?(scope, filter))
        end

      assign(socket, panel: :edit, form: form)
    else
      close_panel(socket)
    end
  end

  defp put_panel(socket, "filters"), do: assign(socket, panel: :filters, form: nil)
  defp put_panel(socket, _panel), do: close_panel(socket)

  defp close_panel(socket), do: assign(socket, panel: nil, form: nil)

  ## Events

  @impl true
  def handle_event("validate", %{"query" => %{"bql" => bql}}, socket) do
    error =
      case QueryData.parse(bql) do
        :ok -> nil
        {:error, error} -> Map.put(error, :bql, bql)
      end

    {:noreply, assign(socket, bql: bql, error: error)}
  end

  def handle_event("run", %{"query" => %{"bql" => bql}}, socket),
    do: {:noreply, submit(socket, bql)}

  def handle_event("example", %{"bql" => bql}, socket), do: {:noreply, submit(socket, bql)}

  def handle_event("rerun", _params, %{assigns: %{ran: ran}} = socket) when is_binary(ran),
    do: {:noreply, run(socket, ran)}

  def handle_event("load_more", _params, socket), do: {:noreply, load_more(socket)}

  def handle_event("toggle_fields", _params, socket),
    do: {:noreply, assign(socket, :fields_open?, !socket.assigns.fields_open?)}

  def handle_event("add_field", %{"name" => name}, socket) do
    bql =
      case String.trim_trailing(socket.assigns.bql) do
        "" -> name <> " "
        text -> text <> " " <> name <> " "
      end

    {:noreply, assign(socket, :bql, bql)}
  end

  def handle_event("save_to", _params, %{assigns: %{base: %{} = base}} = socket) do
    %{current_scope: scope, bql: bql, filter: filter} = socket.assigns

    if filter && QueryData.can_edit?(scope, filter) do
      case QueryData.update_filter(scope, base.id, %{bql: bql, lock_version: base.lock_version}) do
        {:ok, filter} ->
          {:noreply,
           socket
           |> loaded(filter)
           |> put_flash(:info, dgettext("ui", "已保存到 %{name}", name: filter.name))
           |> patch_source({to_string(filter.id), nil})}

        {:error, :not_found} ->
          {:noreply, detach(socket)}

        {:error, :stale} ->
          {:noreply, assign(socket, :conflict, :stale)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, save_failed(socket, changeset)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, FilterForm.failure(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_latest", _params, %{assigns: %{base: %{} = base}} = socket) do
    case QueryData.get_filter(socket.assigns.current_scope, base.id) do
      {:ok, filter} ->
        socket =
          socket
          |> loaded(filter)
          |> assign(:bql, filter.bql)
          |> run(filter.bql)

        socket =
          case socket.assigns.form do
            %{mode: :edit} = form ->
              assign(
                socket,
                :form,
                FilterForm.new(:edit, filter, form.can_change_visibility?)
              )

            _ ->
              socket
          end

        extra = if socket.assigns.panel == :edit, do: %{panel: "edit-filter"}, else: %{}
        {:noreply, patch_source(socket, {to_string(filter.id), nil}, extra)}

      {:error, _} ->
        {:noreply, detach(socket)}
    end
  end

  def handle_event(
        "filter_form_change",
        %{"filter" => params},
        %{assigns: %{form: %{}}} = socket
      ),
      do: {:noreply, assign(socket, :form, FilterForm.change(socket.assigns.form, params))}

  def handle_event("filter_form_submit", %{"filter" => params}, %{assigns: %{form: %{}}} = socket) do
    form = FilterForm.change(socket.assigns.form, params)
    {:noreply, save_form(assign(socket, :form, form), form)}
  end

  def handle_event("ask_delete", _params, %{assigns: %{filter: %{}}} = socket),
    do: {:noreply, assign(socket, :confirm_delete?, true)}

  def handle_event("dismiss", _params, socket),
    do: {:noreply, assign(socket, :confirm_delete?, false)}

  def handle_event("delete", _params, %{assigns: %{base: %{} = base}} = socket) do
    socket = assign(socket, :confirm_delete?, false)

    case QueryData.delete_filter(socket.assigns.current_scope, base.id) do
      {:ok, _filter} ->
        {:noreply,
         socket
         |> unlink()
         |> put_flash(:info, dgettext("ui", "筛选器已删除"))
         |> patch_source({nil, blank(socket.assigns.bql)})}

      {:error, :not_found} ->
        {:noreply, detach(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FilterForm.failure(reason))}
    end
  end

  def handle_event("filter_list", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :list_q, q)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp submit(socket, bql) do
    socket = assign(socket, :bql, bql)
    source = source_for(socket, bql)

    cond do
      source == {nil, nil} -> patch_to(socket, source)
      source == socket.assigns.source -> run(socket, bql)
      true -> patch_to(socket, source)
    end
  end

  defp patch_to(socket, {id, bql}, extra \\ %{}) do
    path = "/w/#{socket.assigns.current_scope.workspace.slug}/query"
    params = Enum.reject([filter: id, bql: bql], fn {_k, v} -> v == nil end)
    push_patch(socket, to: Url.put_params(path, Map.merge(Map.new(params), extra)))
  end

  defp loaded(socket, filter) do
    assign(socket,
      filter: filter,
      base: base(filter),
      conflict: nil,
      page_title: filter.name
    )
  end

  defp unlink(socket) do
    assign(socket,
      filter: nil,
      base: nil,
      conflict: nil,
      panel: nil,
      form: nil,
      confirm_delete?: false,
      page_title: dgettext("ui", "查询")
    )
  end

  # The open filter was deleted or is no longer visible: keep the editor and results.
  defp detach(socket) do
    socket
    |> unlink()
    |> put_flash(:error, dgettext("ui", "筛选器已被删除或你已无权查看"))
    |> patch_source({nil, blank(socket.assigns.bql)})
  end

  defp save_form(socket, %{mode: :create} = form) do
    scope = socket.assigns.current_scope
    attrs = Map.put(FilterForm.attrs(form), :bql, socket.assigns.bql)

    case QueryData.create_filter(scope, attrs) do
      {:ok, filter} ->
        socket
        |> loaded(filter)
        |> assign(panel: nil, form: nil)
        |> run_once(filter.bql)
        |> put_flash(:info, dgettext("ui", "已保存筛选器 %{name}", name: filter.name))
        |> patch_source({to_string(filter.id), nil})

      {:error, reason} ->
        assign(socket, :form, FilterForm.put_error(form, reason))
    end
  end

  defp save_form(%{assigns: %{base: %{} = base}} = socket, %{mode: :edit} = form) do
    scope = socket.assigns.current_scope
    attrs = Map.put(FilterForm.attrs(form), :lock_version, base.lock_version)

    case QueryData.update_filter(scope, base.id, attrs) do
      {:ok, filter} ->
        socket
        |> loaded(filter)
        |> assign(panel: nil, form: nil)
        |> put_flash(:info, dgettext("ui", "筛选器已更新"))
        |> patch_to(socket.assigns.source)

      {:error, :not_found} ->
        detach(socket)

      {:error, reason} ->
        assign(socket, :form, FilterForm.put_error(form, reason))
    end
  end

  defp save_form(socket, _form), do: socket

  # An invalid query shows like a validation error under the editor.
  defp save_failed(socket, changeset) do
    case Keyword.get_values(changeset.errors, :bql) do
      [{message, opts} | _] ->
        error = message |> FilterForm.bql_error(opts) |> Map.put(:bql, socket.assigns.bql)
        assign(socket, :error, error)

      [] ->
        put_flash(socket, :error, FilterForm.failure(:invalid))
    end
  end

  ## Changes elsewhere (forwarded by the shell)

  @impl true
  def handle_info({:filters_changed, _audience}, %{assigns: %{base: %{} = base}} = socket) do
    case QueryData.get_filter(socket.assigns.current_scope, base.id) do
      {:ok, %{lock_version: version} = filter} when version == base.lock_version ->
        {:noreply, assign(socket, :filter, filter)}

      {:ok, filter} ->
        if socket.assigns.bql == base.bql and socket.assigns.panel != :edit do
          socket =
            socket
            |> loaded(filter)
            |> assign(:bql, filter.bql)
            |> run(filter.bql)

          source = {to_string(filter.id), nil}

          {:noreply,
           if(socket.assigns.source == source, do: socket, else: patch_source(socket, source))}
        else
          {:noreply, assign(socket, filter: filter, conflict: :remote)}
        end

      {:error, _} ->
        {:noreply, detach(socket)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  defp modified?(%{base: %{bql: bql}, bql: current}), do: current != bql
  defp modified?(_assigns), do: false

  @doc false
  # 加载更多 stops at the domain's offset limit (10000) and then says so.
  def has_more?(%{loaded: loaded, total: total}), do: loaded < min(total, @max_results)

  @doc false
  def capped?(%{loaded: loaded, total: total}),
    do: total > @max_results and loaded >= @max_results

  defp mine?(filter, scope), do: filter.owner_id == scope.user.id

  defp list_filters(filters, q) do
    q = q |> String.trim() |> String.downcase()

    if q == "",
      do: filters,
      else: Enum.filter(filters, &String.contains?(String.downcase(&1.name), q))
  end

  @impl true
  def render(assigns) do
    scope = assigns.current_scope
    filter = assigns.filter

    assigns =
      assign(assigns,
        slug: scope.workspace.slug,
        modified?: modified?(assigns),
        can_edit?: filter != nil and QueryData.can_edit?(scope, filter),
        close_path: Url.drop_params(assigns.uri || "", ["panel"]),
        filters_path: Url.put_params(assigns.uri || "", %{panel: "filters"}),
        save_path: Url.put_params(assigns.uri || "", %{panel: "save-filter"}),
        edit_path: Url.put_params(assigns.uri || "", %{panel: "edit-filter"})
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={if(@filter, do: @filter.name, else: dgettext("ui", "查询"))}>
          <:crumb :if={@filter}>{dgettext("ui", "筛选器")}</:crumb>
          <:actions>
            <.filter_badges
              :if={@filter}
              filter={@filter}
              mine?={mine?(@filter, @current_scope)}
              modified?={@modified?}
            />
            <.dropdown
              :if={@can_edit?}
              id="query-filter-menu"
              label={dgettext("ui", "筛选器操作")}
              align={:end}
              items={[
                %{
                  id: "query-filter-menu-edit",
                  label: dgettext("ui", "编辑"),
                  icon: "lucide-pencil",
                  patch: @edit_path
                },
                %{
                  id: "query-filter-menu-delete",
                  label: dgettext("ui", "删除"),
                  icon: "lucide-trash",
                  danger: true,
                  on_select: "ask_delete"
                }
              ]}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
            <.button
              id="query-all-filters"
              size="sm"
              icon="lucide-list-filter"
              patch={@filters_path}
            >
              {dgettext("ui", "全部筛选器")}
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="flex flex-col gap-4 px-4 py-4 lg:px-6">
        <div
          :if={@conflict}
          id="query-conflict"
          role="alert"
          class="flex flex-wrap items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <.icon name="lucide-triangle-alert" class="size-4 flex-none" />
          <span class="flex-1">
            {if(@conflict == :stale,
              do: dgettext("ui", "这个筛选器刚被修改"),
              else: dgettext("ui", "这个筛选器已被他人修改")
            )}
          </span>
          <.button id="query-load-latest" size="sm" phx-click="load_latest">
            {dgettext("ui", "载入最新")}
          </.button>
        </div>

        <.form
          for={%{}}
          as={:query}
          id="query-form"
          phx-change="validate"
          phx-submit="run"
          class="flex flex-col gap-2"
        >
          <label for="query-bql" class="sr-only">BQL</label>
          <textarea
            id="query-bql"
            name="query[bql]"
            rows="3"
            phx-hook="Editor"
            data-submit="mod-enter-form"
            phx-debounce="300"
            spellcheck="false"
            autocomplete="off"
            placeholder={dgettext("ui", "例如 status = new AND assignee = currentUser()")}
            aria-invalid={@error && "true"}
            aria-describedby={@error && "query-error-message"}
            class={[
              "w-full rounded-field border bg-surface px-3 py-1.5 font-mono text-body leading-5 text-fg focus:outline-none",
              "border-border-strong focus:border-brand",
              @error && "border-danger focus:border-danger"
            ]}
          >{@bql}</textarea>
          <.query_error :if={@error} error={@error} />
          <div class="flex flex-wrap items-center gap-2">
            <.button id="query-run" type="submit" variant="primary" icon="lucide-play">
              {dgettext("ui", "运行")}
              <:kbd>
                <.kbd mod>Enter</.kbd>
              </:kbd>
            </.button>
            <.button
              :if={@can_save? and @can_edit? and @modified?}
              id="query-save-to"
              phx-click="save_to"
            >
              {dgettext("ui", "保存到 %{name}", name: @filter.name)}
            </.button>
            <.button :if={@can_save? and @filter} id="query-save-as" patch={@save_path}>
              {dgettext("ui", "另存为…")}
            </.button>
            <.button
              :if={@can_save? and !@filter}
              id="query-save-new"
              patch={@save_path}
              disabled_reason={if(String.trim(@bql) == "", do: dgettext("ui", "先输入查询"))}
            >
              {dgettext("ui", "另存为筛选器")}
            </.button>
            <.button
              id="query-toggle-fields"
              variant="ghost"
              icon="lucide-book-open"
              phx-click="toggle_fields"
              aria-expanded={to_string(@fields_open?)}
              aria-controls="query-fields"
            >
              {dgettext("ui", "字段速查")}
            </.button>
          </div>
        </.form>

        <.fields_reference :if={@fields_open?} fields={@fields} />

        <.example_list :if={@result == nil and @ran in [nil, ""] and @error == nil} />

        <section :if={@result} id="query-results" class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center gap-3 text-body">
            <span id="query-total" class="font-medium text-fg">
              {dgettext("ui", "共 %{n} 个任务", n: @result.total)}
            </span>
            <span :if={order_label(@result.order)} id="query-order" class="text-fg-muted">
              {order_label(@result.order)}
            </span>
            <.badge :if={@stale?} id="query-stale" tone={:warning}>{dgettext("ui", "已过期")}</.badge>
            <.button
              id="query-rerun"
              size="sm"
              variant="ghost"
              icon="lucide-refresh-cw"
              phx-click="rerun"
            >
              {dgettext("ui", "重新运行")}
            </.button>
          </div>
          <.result_table
            rows={@streams.tasks}
            slug={@slug}
            agents={@agents}
            has_more={has_more?(@result)}
            class={@result.total == 0 && "hidden"}
          />
          <p
            :if={@result.total == 0}
            id="query-empty"
            class="py-6 text-center text-body text-fg-muted"
          >
            {dgettext("ui", "没有符合条件的任务")}
          </p>
          <p :if={capped?(@result)} id="query-capped" class="text-center text-body text-fg-muted">
            {dgettext("ui", "最多显示 10000 个结果，请缩小范围")}
          </p>
        </section>
      </div>

      <FilterForm.panel :if={@can_save?} form={@form} close_path={@close_path} />

      <.side_panel
        id="filters-panel"
        show={@panel == :filters}
        title={dgettext("ui", "全部筛选器")}
        patch_on_close={@close_path}
      >
        <form id="filters-panel-search" phx-change="filter_list" class="mb-4">
          <.input
            id="filters-panel-q"
            name="q"
            type="search"
            value={@list_q}
            placeholder={dgettext("ui", "按名字过滤")}
            aria-label={dgettext("ui", "按名字过滤")}
            autocomplete="off"
          />
        </form>
        <.filter_group
          id="filters-panel-mine"
          title={dgettext("ui", "我的")}
          filters={list_filters(@shell.filters.mine, @list_q)}
          slug={@slug}
        />
        <.filter_group
          id="filters-panel-shared"
          title={dgettext("ui", "共享")}
          filters={list_filters(@shell.filters.shared, @list_q)}
          slug={@slug}
          owners
        />
      </.side_panel>

      <.confirm_dialog
        :if={@can_edit?}
        id="delete-filter-dialog"
        show={@confirm_delete?}
        title={dgettext("ui", "删除筛选器 %{name}？", name: @filter.name)}
        danger
        confirm_label={dgettext("ui", "删除")}
        on_confirm="delete"
        on_cancel={JS.push("dismiss")}
      >
        {dgettext("ui", "删除后侧栏与他人的列表里都不再有它。")}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :filter, :map, required: true
  attr :mine?, :boolean, required: true
  attr :modified?, :boolean, required: true

  defp filter_badges(assigns) do
    assigns = assign(assigns, :owner, QueryData.owner_name(assigns.filter))

    ~H"""
    <span id="query-filter-badges" class="flex items-center gap-1.5">
      <.badge :if={@filter.visibility == :workspace} id="query-filter-shared" tone={:info}>
        {dgettext("ui", "共享")}
      </.badge>
      <span :if={!@mine? and @owner} id="query-filter-owner" class="text-caption text-fg-muted">
        {dgettext("ui", "所有者：%{name}", name: @owner)}
      </span>
      <span :if={!@owner} id="query-filter-owner-left" class="text-caption text-fg-muted">
        {dgettext("ui", "所有者已离开")}
      </span>
      <.badge :if={@modified?} id="query-filter-modified" tone={:warning}>
        {dgettext("ui", "已修改")}
      </.badge>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :filters, :list, required: true
  attr :slug, :string, required: true
  attr :owners, :boolean, default: false

  defp filter_group(assigns) do
    ~H"""
    <section id={@id} class="mb-4 flex flex-col gap-1">
      <h3 class="text-label font-medium text-fg-muted">{@title}</h3>
      <p :if={@filters == []} class="text-body text-fg-subtle" data-empty>
        {dgettext("ui", "没有筛选器")}
      </p>
      <.link
        :for={filter <- @filters}
        id={"#{@id}-#{filter.id}"}
        patch={"/w/#{@slug}/query?filter=#{filter.id}"}
        class="flex h-8 items-center gap-2 rounded-field px-2 text-body text-fg hover:bg-hover"
      >
        <span class="truncate" data-name>{filter.name}</span>
        <.badge :if={!filter.valid_bql} tone={:danger} data-invalid>
          {dgettext("ui", "BQL 无效")}
        </.badge>
        <span :if={@owners} class="ml-auto truncate text-caption text-fg-muted" data-owner>
          {QueryData.owner_name(filter) || dgettext("ui", "所有者已离开")}
        </span>
      </.link>
    </section>
    """
  end
end

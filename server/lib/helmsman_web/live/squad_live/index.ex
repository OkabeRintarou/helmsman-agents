defmodule HelmsmanWeb.SquadLive.Index do
  @moduledoc """
  `/w/:slug/squads` (spec web-squads 小队列表页, add-squads-autopilots-ui D2): every squad
  of the workspace, the new-squad panel (`?panel=new-squad`) and the conversation entry.

  `{:squad, _}` (the shell alone subscribes to the squad topic, add-actor-avatars D7),
  `{:agents_changed}` / `{:runtimes_changed}` and `{:avatars_changed}`, all forwarded by
  the shell (leaders' and members' state, the current user's availability, the marks),
  reload the list through `HelmsmanWeb.Throttle`.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SquadComponents

  alias Helmsman.Policy
  alias HelmsmanWeb.{SquadData, SquadForm, Throttle, Url}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "小队"),
       can_create?: Policy.authorize(scope, :manage_squads) == :ok,
       uri: nil,
       squad_form: nil,
       form_gen: 0,
       empty?: true
     )
     |> stream_configure(:squads, dom_id: &"squad-#{&1.id}")
     |> stream(:squads, [])
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    socket = assign(socket, :uri, if(query, do: "#{path}?#{query}", else: path))

    open? = params["panel"] == "new-squad" and socket.assigns.can_create?

    {:noreply, open_form(socket, open?)}
  end

  defp open_form(socket, false), do: assign(socket, :squad_form, nil)
  defp open_form(%{assigns: %{squad_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    gen = socket.assigns.form_gen + 1

    socket
    |> assign(:form_gen, gen)
    |> assign(:squad_form, SquadForm.new(socket.assigns.current_scope, gen))
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    squads =
      case SquadData.list(scope) do
        {:ok, squads} -> squads
        {:error, _} -> []
      end

    availability = SquadData.availability(scope)
    rows = Enum.map(squads, &Map.put(&1, :availability, availability[&1.name]))

    socket
    |> assign(:empty?, squads == [])
    |> stream(:squads, rows, reset: true)
  end

  @impl true
  def handle_event("squad_form_" <> _ = event, params, socket) do
    case SquadForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        slug = socket.assigns.current_scope.workspace.slug

        {:noreply,
         socket
         |> saved_flash(view)
         |> push_navigate(to: Url.squad_path(slug, view.name))}

      {:forbidden, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("ui", "没有权限执行此操作"))
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      result ->
        result
    end
  end

  @doc """
  The flashes after saving (spec web-squads 新建与编辑小队): 已保存, plus a warning (the
  error flash, as the other pages do) with the 可触发 summary and the cancelled runs of
  a leader change.
  """
  def saved_flash(socket, view) do
    socket = put_flash(socket, :info, dgettext("ui", "已保存 %{name}", name: view.name))

    case warnings(view) do
      [] -> socket
      list -> put_flash(socket, :error, Enum.join(list, "；"))
    end
  end

  defp warnings(view) do
    summary = view[:trigger_summary]

    restricted =
      if summary && summary.able < summary.total do
        [
          dgettext("ui", "能触发这个小队的成员 %{able} / %{total}：%{names} 只允许所属用户触发",
            able: summary.able,
            total: summary.total,
            names: Enum.join(summary.restricted, "、")
          )
        ]
      else
        []
      end

    cancelled =
      case view[:cancelled_runs] do
        [_ | _] = list ->
          [
            dgettext(
              "ui",
              "已取消旧 leader 在 %{tasks} 上排队的运行，可以重新指派或 @%{name}",
              tasks: Enum.join(list, "、"),
              name: view.name
            )
          ]

        _ ->
          []
      end

    restricted ++ cancelled
  end

  @impl true
  def handle_info({:squad, _id}, socket), do: {:noreply, Throttle.schedule(socket)}

  def handle_info(message, socket)
      when message in [{:agents_changed}, {:runtimes_changed}, {:avatars_changed}],
      do: {:noreply, Throttle.schedule(socket)}

  def handle_info(:reload, socket), do: {:noreply, socket |> Throttle.done() |> load()}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    slug = assigns.current_scope.workspace.slug

    assigns =
      assign(assigns,
        slug: slug,
        new_path: Url.put_params(assigns.uri || "", %{panel: "new-squad"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"]),
        design_path: Url.agent_design_path(slug) <> "?kind=squad"
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "小队")}>
          <:actions :if={@can_create?}>
            <.button
              id="squads-design"
              size="sm"
              icon="lucide-messages-square"
              navigate={@design_path}
            >
              {dgettext("ui", "用对话创建")}
            </.button>
            <.button
              id="squads-new"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_path}
            >
              {dgettext("ui", "新建小队")}
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="px-4 py-4 lg:px-6">
        <div :if={@empty?} id="squads-empty">
          <.empty_state
            icon="lucide-users"
            title={dgettext("ui", "还没有小队")}
            description={dgettext("ui", "把任务交给小队，由 leader 决定谁来做、怎么拆")}
          >
            <:action :if={@can_create?}>
              <.button
                id="squads-empty-design"
                size="sm"
                icon="lucide-messages-square"
                navigate={@design_path}
              >
                {dgettext("ui", "用对话创建")}
              </.button>
              <.button
                id="squads-empty-new"
                variant="primary"
                size="sm"
                icon="lucide-plus"
                patch={@new_path}
              >
                {dgettext("ui", "新建小队")}
              </.button>
            </:action>
          </.empty_state>
        </div>

        <.data_table
          :if={!@empty?}
          id="squads"
          rows={@streams.squads}
          label={dgettext("ui", "小队")}
          rich
          row_click={&JS.navigate(Url.squad_path(@slug, &1.name))}
        >
          <:col :let={s} label={dgettext("ui", "小队")} class="w-[30%]">
            <span class="flex min-w-0 flex-col">
              <.link navigate={Url.squad_path(@slug, s.name)} class="min-w-0" data-squad-link>
                <.actor_chip actor={
                  Appearance.decorate(
                    %{
                      name: s.name,
                      kind: :squad,
                      state: if(s.disabled, do: :disabled, else: :active)
                    },
                    @appearance
                  )
                } />
              </.link>
              <span
                :if={(s.description || "") != ""}
                class="truncate text-caption text-fg-muted"
                data-description
              >
                {s.description}
              </span>
            </span>
          </:col>
          <:col :let={s} label="Leader">
            <span class="flex min-w-0 items-center gap-1.5" data-leader>
              <.actor_chip actor={
                Appearance.decorate(%{name: s.leader.name, kind: :agent}, @appearance)
              } />
              <.badge :if={s.leader.archived} tone={:warning} data-leader-archived>
                {dgettext("ui", "已归档")}
              </.badge>
              <.badge :if={s.leader.disabled and !s.leader.archived} data-leader-disabled>
                {dgettext("ui", "已停用")}
              </.badge>
            </span>
          </:col>
          <:col :let={s} label={dgettext("ui", "成员")} secondary>
            <.member_stack members={s.members} appearance={@appearance} />
          </:col>
          <:col :let={s} label={dgettext("ui", "你能否触发")} secondary>
            <.tooltip
              :if={!s.disabled && unavailable_reason(s.name, s.availability)}
              text={unavailable_reason(s.name, s.availability)}
            >
              <span class="inline-flex items-center gap-1 text-warning-fg" data-unavailable>
                <.icon name="lucide-triangle-alert" class="size-3.5" />
                {short_reason(s)}
              </span>
            </.tooltip>
          </:col>
          <:col :let={s} label="" class="w-20 text-right">
            <.badge :if={s.disabled} data-disabled>{dgettext("ui", "已停用")}</.badge>
          </:col>
        </.data_table>
      </div>

      <SquadForm.panel
        :if={@can_create?}
        form={@squad_form}
        scope={@current_scope}
        appearance={@appearance}
        close_path={@close_path}
      />
    </Layouts.app>
    """
  end

  defp short_reason(squad) do
    if refused(squad.availability) != [],
      do: dgettext("ui", "你无权触发"),
      else: unavailable_reason(squad.name, squad.availability)
  end
end

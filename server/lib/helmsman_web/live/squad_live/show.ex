defmodule HelmsmanWeb.SquadLive.Show do
  @moduledoc """
  `/w/:slug/squads/*name` (spec web-squads 小队详情页, add-squads-autopilots-ui D3, D5):
  description, instructions, the leader and members in order, the 可触发 summary and
  whether the current user can trigger the squad; 编辑 (`?panel=edit`), 停用 / 启用 for
  those who manage it.

  `{:squad, id}` of this squad, and `{:agents_changed}` / `{:runtimes_changed}`, all
  forwarded by the shell (which alone subscribes to the squad topic, add-actor-avatars
  D7), reload it through `HelmsmanWeb.Throttle`; a rename patches to the new path. The
  page header holds the squad's avatar (`HelmsmanWeb.AvatarEditor`).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SquadComponents

  alias HelmsmanWeb.{AvatarData, SquadData, SquadForm, Throttle, Url}
  alias HelmsmanWeb.SquadLive.Index

  @fold_bytes 2048

  @impl true
  def mount(%{"name" => segments}, _session, socket) do
    scope = socket.assigns.current_scope
    name = Url.agent_name(segments)

    case SquadData.get(scope, name) do
      {:ok, squad} ->
        {:ok,
         socket
         |> assign(
           page_title: squad.name,
           uri: nil,
           squad_form: nil,
           form_gen: 0,
           confirm_disable: false,
           gone?: false,
           expanded?: false
         )
         |> put_squad(squad)
         |> put_avatar_rights()}

      _error ->
        raise HelmsmanWeb.NotFoundError
    end
  end

  defp member_actor(agent, appearance) do
    actor = %{
      name: agent.name,
      kind: :agent,
      provider: agent[:provider],
      state: if(agent[:disabled], do: :disabled, else: :active)
    }

    Appearance.decorate(actor, appearance)
  end

  defp put_avatar_rights(socket) do
    target = {:actor, socket.assigns.squad.name}
    assign(socket, :avatar_rights, AvatarData.can_manage?(socket.assigns.current_scope, target))
  end

  defp put_squad(socket, squad) do
    availability = SquadData.availability(socket.assigns.current_scope)

    assign(socket,
      squad: squad,
      page_title: squad.name,
      availability: availability[squad.name]
    )
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    socket = assign(socket, :uri, if(query, do: "#{path}?#{query}", else: path))

    open? =
      params["panel"] == "edit" and socket.assigns.squad.can_manage and not socket.assigns.gone?

    {:noreply, open_form(socket, open?)}
  end

  defp open_form(socket, false), do: assign(socket, :squad_form, nil)
  defp open_form(%{assigns: %{squad_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    gen = socket.assigns.form_gen + 1
    form = SquadForm.edit(socket.assigns.current_scope, gen, socket.assigns.squad)
    assign(socket, form_gen: gen, squad_form: form)
  end

  defp slug(socket), do: socket.assigns.current_scope.workspace.slug

  @impl true
  def handle_event("squad_form_" <> _ = event, params, socket) do
    case SquadForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        {:noreply,
         socket
         |> put_squad(view)
         |> assign(:squad_form, nil)
         |> Index.saved_flash(view)
         |> push_patch(to: Url.squad_path(slug(socket), view.name))}

      {:forbidden, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("ui", "没有权限执行此操作"))
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      result ->
        result
    end
  end

  def handle_event("toggle_instructions", _params, socket),
    do: {:noreply, assign(socket, :expanded?, !socket.assigns.expanded?)}

  def handle_event("ask_disable", _params, socket),
    do: {:noreply, assign(socket, :confirm_disable, true)}

  def handle_event("dismiss_disable", _params, socket),
    do: {:noreply, assign(socket, :confirm_disable, false)}

  def handle_event("disable", _params, socket) do
    socket = assign(socket, :confirm_disable, false)
    result = SquadData.disable(socket.assigns.current_scope, socket.assigns.squad.name)

    {:noreply,
     after_toggle(socket, result, dgettext("ui", "已停用 %{name}", name: socket.assigns.squad.name))}
  end

  def handle_event("enable", _params, socket) do
    result = SquadData.enable(socket.assigns.current_scope, socket.assigns.squad.name)

    message =
      dgettext("ui", "已启用 %{name}；停用期间错过的工作不会补派", name: socket.assigns.squad.name)

    {:noreply, after_toggle(socket, result, message)}
  end

  defp after_toggle(socket, {:ok, view}, message),
    do: socket |> put_squad(view) |> put_flash(:info, message)

  defp after_toggle(socket, {:error, :forbidden}, _message),
    do: put_flash(socket, :error, dgettext("ui", "没有权限执行此操作"))

  defp after_toggle(socket, {:error, _reason}, _message),
    do: put_flash(socket, :error, dgettext("ui", "操作失败，请重试"))

  @impl true
  def handle_info({:squad, id}, %{assigns: %{squad: %{id: id}}} = socket),
    do: {:noreply, Throttle.schedule(socket)}

  def handle_info({:squad, _id}, socket), do: {:noreply, socket}

  def handle_info(message, socket) when message in [{:agents_changed}, {:runtimes_changed}],
    do: {:noreply, Throttle.schedule(socket)}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> Throttle.done() |> reload() |> put_avatar_rights()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Reads the squad by its id among the list, so a rename is followed (D3).
  defp reload(socket) do
    %{squad: squad, current_scope: scope} = socket.assigns

    case SquadData.list(scope) do
      {:ok, squads} -> follow(socket, squad, Enum.find(squads, &(&1.id == squad.id)))
      {:error, _} -> socket
    end
  end

  defp follow(socket, _squad, nil), do: assign(socket, gone?: true, squad_form: nil)

  defp follow(socket, %{name: name}, %{name: name} = fresh), do: put_squad(socket, fresh)

  # A rename keeps the query (an open panel) and the panel's draft and version; the form
  # follows the new name so that saving still reports a conflict (code-review-1 P2-1).
  defp follow(socket, _squad, fresh) do
    query = URI.parse(socket.assigns.uri || "").query
    path = Url.squad_path(slug(socket), fresh.name)

    socket
    |> put_squad(fresh)
    |> rename_form(fresh.name)
    |> push_patch(to: if(query, do: "#{path}?#{query}", else: path))
  end

  defp rename_form(%{assigns: %{squad_form: %{} = form}} = socket, name),
    do: assign(socket, :squad_form, %{form | name: name})

  defp rename_form(socket, _name), do: socket

  @impl true
  def render(assigns) do
    squad = assigns.squad

    assigns =
      assign(assigns,
        slug: assigns.current_scope.workspace.slug,
        edit_path: Url.put_params(assigns.uri || "", %{panel: "edit"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"]),
        fold?: byte_size(squad.instructions || "") > @fold_bytes,
        reason: unavailable_reason(squad.name, assigns.availability),
        refused: refused(assigns.availability)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@squad.name}>
          <:crumb navigate={"/w/#{@slug}/squads"}>{dgettext("ui", "小队")}</:crumb>
          <:leading>
            <.live_component
              module={HelmsmanWeb.AvatarEditor}
              id="squad-avatar"
              scope={@current_scope}
              target={{:actor, @squad.name}}
              rights={@avatar_rights}
              size={:lg}
              actor={
                Appearance.decorate(
                  %{
                    name: @squad.name,
                    kind: :squad,
                    state: if(@squad.disabled, do: :disabled, else: :active)
                  },
                  @appearance
                )
              }
            />
          </:leading>
          <:actions>
            <.badge :if={@squad.disabled} id="squad-disabled-badge">{dgettext("ui", "已停用")}</.badge>
            <.button
              :if={@squad.can_manage and not @gone?}
              id="squad-edit"
              size="sm"
              icon="lucide-pencil"
              patch={@edit_path}
            >
              {dgettext("ui", "编辑")}
            </.button>
            <.button
              :if={@squad.can_manage and not @gone?}
              id="squad-design-edit"
              size="sm"
              icon="lucide-messages-square"
              navigate={
                HelmsmanWeb.Url.agent_design_edit_path(@current_scope.workspace.slug, @squad.name)
              }
            >
              {dgettext("ui", "用对话修改")}
            </.button>
            <.button
              :if={@squad.can_manage and not @squad.disabled and not @gone?}
              id="squad-disable"
              size="sm"
              icon="lucide-pause"
              phx-click="ask_disable"
            >
              {dgettext("ui", "停用")}
            </.button>
            <.button
              :if={@squad.can_manage and @squad.disabled and not @gone?}
              id="squad-enable"
              size="sm"
              icon="lucide-play"
              phx-click="enable"
            >
              {dgettext("ui", "启用")}
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="flex flex-col gap-6 px-4 py-4 lg:flex-row lg:px-6">
        <div class="flex min-w-0 flex-1 flex-col gap-6">
          <div
            :if={@gone?}
            id="squad-gone"
            role="status"
            class="flex items-center gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
          >
            <.icon name="lucide-circle-alert" class="size-4" />
            {dgettext("ui", "这个小队已不存在")}
            <.link navigate={"/w/#{@slug}/squads"} class="underline">{dgettext("ui", "返回小队列表")}</.link>
          </div>
          <div
            :if={@squad.leader.archived}
            id="squad-leader-archived"
            role="status"
            class="flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="size-4" />
            {dgettext("ui", "leader 已归档：小队不能被触发，请换一个 leader")}
          </div>

          <section class="flex flex-col gap-2">
            <p :if={(@squad.description || "") != ""} id="squad-description" class="text-body text-fg">
              {@squad.description}
            </p>
            <p id="squad-spec-finalize" class="text-caption text-fg-muted">
              {dgettext("ui", "规格定稿方式：%{mode}",
                mode: spec_finalize_label(Map.get(@squad, :spec_finalize))
              )}
            </p>
            <div
              :if={(@squad.instructions || "") != ""}
              id="squad-instructions"
              class="flex flex-col gap-1"
            >
              <div class="flex items-center gap-2">
                <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "说明")}</h2>
                <span class="text-caption text-fg-subtle">
                  {dgettext("ui", "%{n} 字节", n: byte_size(@squad.instructions))}
                </span>
                <.button
                  :if={@fold?}
                  id="squad-instructions-toggle"
                  size="xs"
                  variant="ghost"
                  phx-click="toggle_instructions"
                  aria-expanded={to_string(@expanded?)}
                >
                  {if(@expanded?, do: dgettext("ui", "收起"), else: dgettext("ui", "展开"))}
                </.button>
              </div>
              <div :if={not @fold? or @expanded?} id="squad-instructions-body">
                <.markdown
                  content={@squad.instructions}
                  scope={@current_scope}
                  anchor_ns="squad-instructions"
                />
              </div>
            </div>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "成员")}</h2>
            <ol
              id="squad-members"
              class="flex flex-col divide-y divide-border rounded-field border border-border"
            >
              <li
                id="squad-member-leader"
                data-member={@squad.leader.name}
                class="flex flex-col gap-1 px-3 py-2"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <.link navigate={Url.agent_path(@slug, @squad.leader.name)} class="min-w-0">
                    <.actor_chip actor={member_actor(@squad.leader, @appearance)} />
                  </.link>
                  <.badge tone={:brand}>Leader</.badge>
                  <.badge :if={@squad.leader.archived} tone={:warning}>
                    {dgettext("ui", "已归档")}
                  </.badge>
                  <.badge :if={@squad.leader.disabled and not @squad.leader.archived}>
                    {dgettext("ui", "已停用")}
                  </.badge>
                  <.member_config agent={@squad.leader} data-config />
                </div>
              </li>
              <li
                :for={{m, i} <- Enum.with_index(@squad.members)}
                id={"squad-member-#{i}"}
                data-member={m.name}
                class="flex flex-col gap-1 px-3 py-2"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    :if={m.kind == "agent"}
                    navigate={Url.agent_path(@slug, m.name)}
                    class="min-w-0"
                  >
                    <.actor_chip actor={member_actor(m, @appearance)} />
                  </.link>
                  <.actor_chip
                    :if={m.kind != "agent"}
                    actor={Appearance.decorate(%{name: m.name, kind: :human}, @appearance)}
                  />
                  <span class="text-caption text-fg-subtle" data-kind>
                    {if(m.kind == "agent", do: dgettext("ui", "托管 Agent"), else: dgettext("ui", "人"))}
                  </span>
                  <.badge :if={m.disabled} data-member-disabled>{dgettext("ui", "已停用")}</.badge>
                  <.member_config agent={m} data-config />
                </div>
                <p :if={(m.role_note || "") != ""} class="text-body text-fg" data-role-note>
                  {m.role_note}
                </p>
              </li>
            </ol>
          </section>
        </div>

        <aside class="flex w-full flex-col gap-4 lg:w-80">
          <section class="flex flex-col gap-2 rounded-field border border-border px-3 py-3">
            <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "谁能触发")}</h2>
            <.trigger_summary id="squad-trigger-summary" summary={@squad.trigger_summary} />
          </section>
          <section
            id="squad-you"
            class="flex flex-col gap-2 rounded-field border border-border px-3 py-3"
          >
            <h2 class="text-label font-medium text-fg-muted">{dgettext("ui", "你能否触发")}</h2>
            <p
              :if={@reason == nil}
              class="flex items-center gap-1.5 text-body text-fg"
              data-can-trigger
            >
              <.icon name="lucide-circle-check" class="size-4 text-success" />
              {dgettext("ui", "可以：把任务指派给它或 @%{name}", name: @squad.name)}
            </p>
            <div :if={@reason} class="flex flex-col gap-1" data-cannot-trigger>
              <p class="flex items-center gap-1.5 text-body text-warning-fg">
                <.icon name="lucide-triangle-alert" class="size-4" />{@reason}
              </p>
              <p :if={@refused != []} class="flex flex-wrap gap-2 text-caption">
                <.link
                  :for={name <- @refused}
                  navigate={Url.agent_path(@slug, name)}
                  class="underline"
                  data-refused
                >
                  {name}
                </.link>
              </p>
            </div>
          </section>
        </aside>
      </div>

      <SquadForm.panel
        :if={@squad.can_manage}
        form={@squad_form}
        scope={@current_scope}
        appearance={@appearance}
        close_path={@close_path}
      />

      <.confirm_dialog
        :if={@squad.can_manage}
        id="squad-disable-dialog"
        show={@confirm_disable}
        title={dgettext("ui", "停用 %{name}？", name: @squad.name)}
        danger
        confirm_label={dgettext("ui", "停用")}
        on_confirm="disable"
        on_cancel={JS.push("dismiss_disable")}
      >
        {dgettext(
          "ui",
          "停用后，排队中的 leader 运行会被取消、进行中的会被停止；它不能再被指派或 @，已指派给它的任务保留。"
        )}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  # add-spec-workflow-ui D17
  defp spec_finalize_label(:leader), do: dgettext("ui", "Leader 定稿")
  defp spec_finalize_label(:approval), do: dgettext("ui", "需要人批准")
  defp spec_finalize_label(_inherit), do: dgettext("ui", "继承项目")
end

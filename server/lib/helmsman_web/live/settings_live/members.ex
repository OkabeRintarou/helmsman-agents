defmodule HelmsmanWeb.SettingsLive.Members do
  @moduledoc """
  Members settings `/w/:slug/settings/members` (spec web-workspace-settings 成员列表页 …
  成员页实时刷新, design D6): the member table with role menus and removal, the invite
  panel (`?panel=invite`) and the pending invitations (admin and above).

  Which controls show is computed with `Helmsman.Policy.authorize/3`, the same check
  the domain runs; events carry only ids and the domain decides. Errors reload the
  lists. `{:members_changed}` (forwarded by the shell) reloads members and invitations.

  The invitation link exists only in `@invite_result` while the panel shows it.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SettingsComponents

  alias Helmsman.{Invitations, Members, Policy}
  alias HelmsmanWeb.{FormErrors, Roles, Url}
  alias HelmsmanWeb.SettingsLive.Errors

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "成员"),
       can_manage?: Policy.authorize(scope, :manage_invitations) == :ok,
       invite_roles:
         Enum.filter(Roles.all(), &(Policy.authorize(scope, :create_invitation, &1) == :ok)),
       members: %{},
       invitations: %{},
       confirm: nil,
       invite: nil,
       invite_result: nil,
       uri: nil
     )
     |> stream_configure(:members, dom_id: &"member-#{&1.membership_id}")
     |> stream_configure(:invitations, dom_id: &"invitation-#{&1.id}")
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    open? = params["panel"] == "invite" and socket.assigns.can_manage?

    invite =
      cond do
        not open? -> nil
        socket.assigns.invite -> socket.assigns.invite
        true -> %{params: %{"email" => "", "role" => "member"}, errors: %{}, error: nil}
      end

    {:noreply,
     assign(socket,
       uri: if(query, do: "#{path}?#{query}", else: path),
       invite: invite,
       invite_result: if(open?, do: socket.assigns.invite_result)
     )}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    members =
      case Members.list(scope) do
        {:ok, members} -> members
        {:error, _} -> []
      end

    invitations =
      with true <- socket.assigns.can_manage?,
           {:ok, invitations} <- Invitations.list_pending(scope) do
        invitations
      else
        _ -> []
      end

    owners = Enum.count(members, &(&1.role == :owner))

    socket
    |> assign(
      owners: owners,
      members: Map.new(members, &{&1.membership_id, &1}),
      invitations: Map.new(invitations, &{&1.id, &1}),
      invitations_empty?: invitations == []
    )
    |> stream(:members, members, reset: true)
    |> stream(:invitations, invitations, reset: true)
  end

  ## Roles

  @impl true
  def handle_event("change_role", %{"id" => id, "role" => role}, socket) do
    with {:ok, member} <- fetch(socket.assigns.members, id),
         {:ok, role} <- cast_role(role) do
      if member.user_id == socket.assigns.current_scope.user.id and role != member.role,
        do: {:noreply, assign(socket, :confirm, %{kind: :demote_self, id: id, role: role})},
        else: change_role(socket, member, role)
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("confirm_role", %{"id" => id, "role" => role}, socket) do
    with {:ok, member} <- fetch(socket.assigns.members, id),
         {:ok, role} <- cast_role(role) do
      change_role(socket, member, role)
    else
      :error -> {:noreply, socket}
    end
  end

  ## Removal

  def handle_event("ask_remove", %{"id" => id}, socket) do
    case fetch(socket.assigns.members, id) do
      {:ok, member} ->
        {:noreply,
         assign(socket, :confirm, %{
           kind: :remove,
           id: member.membership_id,
           name: member.display_name
         })}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case fetch(socket.assigns.members, id) do
      {:ok, member} -> {:noreply, remove(socket, member)}
      :error -> {:noreply, socket}
    end
  end

  ## Invitations

  def handle_event("ask_revoke", %{"id" => id}, socket) do
    case fetch(socket.assigns.invitations, id) do
      {:ok, invitation} ->
        {:noreply, assign(socket, :confirm, %{kind: :revoke, id: invitation.id})}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case fetch(socket.assigns.invitations, id) do
      {:ok, invitation} -> {:noreply, revoke(socket, invitation)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("validate_invite", %{"invite" => params}, %{assigns: %{invite: %{}}} = socket) do
    params = Map.take(params, ~w(email role))
    {:noreply, assign(socket, :invite, %{socket.assigns.invite | params: params})}
  end

  def handle_event("invite", %{"invite" => params}, %{assigns: %{invite: %{}}} = socket) do
    params = Map.take(params, ~w(email role))
    scope = socket.assigns.current_scope

    case Invitations.create(scope, params, &url(~p"/invite/#{&1}")) do
      {:ok, %{invitation: invitation, token: token}} ->
        result = %{url: url(~p"/invite/#{token}"), email: invitation.email}

        {:noreply,
         socket
         |> assign(
           invite: %{params: %{"email" => "", "role" => "member"}, errors: %{}, error: nil},
           invite_result: result
         )
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        invite = %{
          params: params,
          errors: FormErrors.messages(changeset),
          error: dgettext("ui", "请修正下列错误")
        }

        {:noreply, assign(socket, :invite, invite)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :invite, %{
           socket.assigns.invite
           | params: params,
             error: Errors.message(reason)
         })}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(validate_invite invite),
    do: {:noreply, socket}

  @impl true
  def handle_info(message, socket) when message in [{:members_changed}, {:avatars_changed}],
    do: {:noreply, load(socket)}

  defp change_role(socket, member, role) do
    case Members.change_role(socket.assigns.current_scope, member.membership_id, role) do
      {:ok, _} ->
        message = dgettext("ui", "已修改 %{name} 的角色", name: member.display_name)
        {:noreply, socket |> assign(:confirm, nil) |> load() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  defp remove(socket, member) do
    case Members.remove(socket.assigns.current_scope, member.membership_id) do
      {:ok, _} ->
        message = dgettext("ui", "已移除 %{name}", name: member.display_name)
        socket |> load() |> put_flash(:info, message)

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp revoke(socket, invitation) do
    case Invitations.revoke(socket.assigns.current_scope, invitation.id) do
      {:ok, _} -> socket |> load() |> put_flash(:info, dgettext("ui", "邀请已撤销"))
      {:error, :invalid_invitation} -> failed(socket, :not_found)
      {:error, reason} -> failed(socket, reason)
    end
  end

  defp failed(socket, reason) do
    socket = socket |> assign(:confirm, nil) |> put_flash(:error, Errors.message(reason))
    if Errors.reload?(reason), do: load(socket), else: socket
  end

  defp fetch(map, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Map.fetch(map, id)
      _ -> :error
    end
  end

  defp cast_role(role) when is_binary(role) do
    case Enum.find(Roles.all(), &(Atom.to_string(&1) == role)) do
      nil -> :error
      role -> {:ok, role}
    end
  end

  ## Rendering helpers

  # Roles the scope may give `member`; the menu shows only when one differs from the
  # current role. Changes that would leave no owner are greyed out.
  defp role_items(scope, owners, member) do
    self? = member.user_id == scope.user.id

    allowed =
      Enum.filter(
        Roles.all(),
        &(Policy.authorize(scope, :change_member_role, %{from: member.role, to: &1, self?: self?}) ==
            :ok)
      )

    if Enum.any?(allowed, &(&1 != member.role)),
      do: Enum.map(allowed, &role_item(member, &1, owners))
  end

  defp role_item(member, role, owners) do
    item = %{
      id: "member-#{member.membership_id}-role-#{role}",
      label: Roles.label(role),
      checked: role == member.role
    }

    cond do
      role == member.role ->
        item

      member.role == :owner and owners <= 1 ->
        Map.put(item, :disabled_reason, dgettext("ui", "工作区至少需要一个所有者"))

      true ->
        Map.merge(item, %{
          on_select: "change_role",
          value: %{id: member.membership_id, role: role}
        })
    end
  end

  defp removable?(scope, member),
    do:
      member.user_id != scope.user.id and
        Policy.authorize(scope, :remove_member, member.role) == :ok

  defp revocable?(scope, invitation),
    do: Policy.authorize(scope, :revoke_invitation, invitation.role) == :ok

  defp expires_text(%DateTime{} = at) do
    secs = DateTime.diff(at, DateTime.utc_now(), :second)

    cond do
      secs >= 86_400 -> dgettext("ui", "%{n} 天后", n: div(secs, 86_400))
      secs >= 3600 -> dgettext("ui", "%{n} 小时后", n: div(secs, 3600))
      true -> dgettext("ui", "即将过期")
    end
  end

  defp confirm_title(%{kind: :remove, name: name}),
    do: dgettext("ui", "移除 %{name}？", name: name)

  defp confirm_title(%{kind: :demote_self}), do: dgettext("ui", "降低自己的角色？")
  defp confirm_title(%{kind: :revoke}), do: dgettext("ui", "撤销邀请？")
  defp confirm_title(_), do: ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        invite_path: Url.put_params(assigns.uri || "", %{panel: "invite"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <.settings_page tab={:members} flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:actions :if={@can_manage?}>
        <.button
          id="invite-button"
          variant="primary"
          size="sm"
          icon="lucide-user-plus"
          patch={@invite_path}
        >
          {dgettext("ui", "邀请成员")}
        </.button>
      </:actions>

      <section id="members-section" class="mb-8">
        <.data_table id="members" rows={@streams.members} label={dgettext("ui", "成员")} rich>
          <:col :let={m} label={dgettext("ui", "成员")} class="w-[40%]">
            <span class="flex min-w-0 items-center gap-2">
              <.actor_mark
                actor={Appearance.decorate(%{name: m.actor_name, kind: :human}, @appearance)}
                size={:md}
              />
              <span class="flex min-w-0 flex-col">
                <span class="flex items-center gap-1.5 truncate text-fg">
                  <span class="truncate" data-name>{m.display_name}</span>
                  <.badge :if={m.user_id == @current_scope.user.id} data-self>
                    {dgettext("ui", "你")}
                  </.badge>
                </span>
                <span class="truncate text-caption text-fg-muted" data-email>{m.email}</span>
              </span>
            </span>
          </:col>
          <:col :let={m} label={dgettext("ui", "身份名")} secondary>
            <span class="truncate text-fg-muted" data-actor>{m.actor_name}</span>
          </:col>
          <:col :let={m} label={dgettext("ui", "角色")}>
            <.role_cell member={m} items={role_items(@current_scope, @owners, m)} />
          </:col>
          <:col :let={m} label={dgettext("ui", "加入时间")} secondary>
            <.relative_time
              id={"member-#{m.membership_id}-joined"}
              at={m.joined_at}
              class="text-fg-muted"
            />
          </:col>
          <:col :let={m} label="" class="w-12 text-right">
            <.dropdown
              :if={removable?(@current_scope, m)}
              id={"member-#{m.membership_id}-actions"}
              label={dgettext("ui", "更多操作")}
              align={:end}
              items={[
                %{
                  id: "member-#{m.membership_id}-remove",
                  label: dgettext("ui", "移除成员"),
                  icon: "lucide-user-minus",
                  danger: true,
                  on_select: "ask_remove",
                  value: %{id: m.membership_id}
                }
              ]}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </:col>
        </.data_table>
      </section>

      <.settings_section
        :if={@can_manage?}
        id="invitations-section"
        title={dgettext("ui", "待接受的邀请")}
      >
        <.data_table id="invitations" rows={@streams.invitations} label={dgettext("ui", "待接受的邀请")}>
          <:col :let={i} label={dgettext("ui", "邀请对象")} class="w-[35%]">
            <span class="truncate text-fg" data-target>{i.email || dgettext("ui", "通用链接")}</span>
          </:col>
          <:col :let={i} label={dgettext("ui", "角色")}>
            <span data-role>{Roles.label(i.role)}</span>
          </:col>
          <:col :let={i} label={dgettext("ui", "邀请人")} secondary>
            <span class="truncate text-fg-muted">{i.invited_by && i.invited_by.display_name}</span>
          </:col>
          <:col :let={i} label={dgettext("ui", "到期")} secondary>
            <time
              datetime={DateTime.to_iso8601(i.expires_at)}
              title={Calendar.strftime(i.expires_at, "%Y-%m-%d %H:%M UTC")}
              class="text-fg-muted"
            >
              {expires_text(i.expires_at)}
            </time>
          </:col>
          <:col :let={i} label="" class="w-20 text-right">
            <.button
              :if={revocable?(@current_scope, i)}
              id={"invitation-#{i.id}-revoke"}
              size="xs"
              variant="ghost"
              phx-click="ask_revoke"
              phx-value-id={i.id}
            >
              {dgettext("ui", "撤销")}
            </.button>
          </:col>
        </.data_table>
        <p
          :if={@invitations_empty?}
          id="invitations-empty"
          class="py-6 text-center text-body text-fg-muted"
        >
          {dgettext("ui", "没有待接受的邀请")}
        </p>
      </.settings_section>

      <.side_panel
        :if={@can_manage?}
        id="invite-panel"
        show={@invite != nil}
        title={dgettext("ui", "邀请成员")}
        dirty={@invite != nil and @invite_result == nil and (@invite.params["email"] || "") != ""}
        patch_on_close={@close_path}
      >
        <:error :if={@invite && @invite.error}>{@invite.error}</:error>
        <div :if={@invite_result} id="invite-result" class="flex flex-col gap-3">
          <p class="text-body text-fg">{dgettext("ui", "邀请链接：")}</p>
          <.secret_once id="invite-link" value={@invite_result.url} />
          <p :if={@invite_result.email} id="invite-email-sent" class="text-body text-fg-muted">
            {dgettext("ui", "已向 %{email} 发送邀请邮件", email: @invite_result.email)}
          </p>
        </div>
        <.form
          :if={@invite && !@invite_result}
          for={%{}}
          as={:invite}
          id="invite-form"
          phx-change="validate_invite"
          phx-submit="invite"
          class="flex flex-col gap-4"
        >
          <.input
            id="invite-email"
            name="invite[email]"
            type="email"
            label={dgettext("ui", "邮箱（可选）")}
            value={@invite.params["email"]}
            errors={Map.get(@invite.errors, :email, [])}
            autocomplete="off"
          />
          <p
            :if={(@invite.params["email"] || "") == ""}
            id="invite-generic-warning"
            role="note"
            class="flex gap-2 rounded-field border border-warning tint-warning p-3 text-body text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
            {dgettext("ui", "未填写邮箱将生成通用链接：任何拿到链接的人都能以该角色加入，请只通过可信渠道发送")}
          </p>
          <.input
            id="invite-role"
            name="invite[role]"
            type="select"
            label={dgettext("ui", "角色")}
            value={@invite.params["role"]}
            options={Enum.map(@invite_roles, &{Roles.label(&1), &1})}
            errors={Map.get(@invite.errors, :role, [])}
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div :if={!@invite_result} class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="invite-submit"
              type="submit"
              form="invite-form"
              variant="primary"
              phx-disable-with={dgettext("ui", "正在创建…")}
            >
              {dgettext("ui", "创建邀请")}
            </.button>
          </div>
          <.button :if={@invite_result} id="invite-done" variant="primary" phx-click={cancel}>
            {dgettext("ui", "完成")}
          </.button>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        id="members-confirm"
        show={@confirm != nil}
        title={confirm_title(@confirm)}
        danger={@confirm != nil and @confirm.kind != :demote_self}
        confirm_label={confirm_label(@confirm)}
        on_confirm={confirm_event(@confirm)}
        confirm_value={confirm_value(@confirm)}
        on_cancel={JS.push("dismiss")}
      >
        {confirm_text(@confirm)}
      </.confirm_dialog>
    </.settings_page>
    """
  end

  attr :member, :map, required: true
  attr :items, :list, default: nil

  defp role_cell(%{items: nil} = assigns) do
    ~H"""
    <span data-role>{Roles.label(@member.role)}</span>
    """
  end

  defp role_cell(assigns) do
    ~H"""
    <.dropdown
      id={"member-#{@member.membership_id}-role"}
      items={@items}
      label={dgettext("ui", "修改角色")}
      popover_class="w-48"
    >
      <:trigger>
        <span data-role>{Roles.label(@member.role)}</span>
        <.icon name="lucide-chevron-down" class="size-3.5 text-fg-subtle" />
      </:trigger>
    </.dropdown>
    """
  end

  defp confirm_label(%{kind: :remove}), do: dgettext("ui", "移除")
  defp confirm_label(%{kind: :demote_self}), do: dgettext("ui", "确认修改")
  defp confirm_label(%{kind: :revoke}), do: dgettext("ui", "撤销")
  defp confirm_label(_), do: ""

  defp confirm_event(%{kind: :remove}), do: "remove"
  defp confirm_event(%{kind: :demote_self}), do: "confirm_role"
  defp confirm_event(%{kind: :revoke}), do: "revoke"
  defp confirm_event(_), do: "dismiss"

  defp confirm_value(%{kind: :demote_self, id: id, role: role}), do: %{id: id, role: role}
  defp confirm_value(%{id: id}), do: %{id: id}
  defp confirm_value(_), do: %{}

  defp confirm_text(%{kind: :remove, name: name}),
    do: dgettext("ui", "移除 %{name}？他在本工作区的 Token 将被吊销，名下 Agent 将被停用。", name: name)

  defp confirm_text(%{kind: :demote_self}), do: dgettext("ui", "降低自己的角色后无法自行恢复。")
  defp confirm_text(%{kind: :revoke}), do: dgettext("ui", "撤销后该邀请链接立即失效。")
  defp confirm_text(_), do: ""
end

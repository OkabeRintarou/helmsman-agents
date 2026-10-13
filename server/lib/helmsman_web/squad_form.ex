defmodule HelmsmanWeb.SquadForm do
  @moduledoc """
  The squad side panel (add-squads-autopilots-ui D4): name, description, leader, an
  ordered member list with role notes, and instructions.

  The form is a map in the page's `:squad_form` assign; the page routes the
  `squad_form_*` events to `handle_event/3`, which returns `{:saved, view, socket}`,
  `{:forbidden, socket}` or `{:noreply, socket}`.

  Leader candidates are the workspace's unarchived managed agents; a member may only pick
  their own (admins any). Member candidates are the workspace's humans and unarchived
  managed agents other than the leader. Member errors of the domain start with the
  member's name (domain-request-1 R3) and are shown on that member's row.
  """
  use HelmsmanWeb, :html

  alias Helmsman.{Actors, Agents}
  alias HelmsmanWeb.{FormErrors, MarkdownEditor, SquadData}

  @max_members 16
  @max_description 2048
  @max_note 2048
  @max_instructions 16_384

  @doc "Limits shown in the panel."
  def limits,
    do: %{
      members: @max_members,
      description: @max_description,
      note: @max_note,
      instructions: @max_instructions
    }

  @doc "A form for a new squad."
  def new(scope, gen) do
    base(scope, gen, :new)
    |> Map.merge(%{
      params: %{"name" => "", "description" => "", "instructions" => "", "leader" => ""},
      members: []
    })
  end

  @doc "A form editing the squad `view` (`SquadData.get/2`)."
  def edit(scope, gen, view) do
    base(scope, gen, :edit)
    |> Map.merge(from_view(view))
  end

  defp from_view(view) do
    %{
      name: view.name,
      version: view.lock_version,
      params: %{
        "name" => view.name,
        "description" => view.description || "",
        "instructions" => view.instructions || "",
        "leader" => view.leader.name
      },
      members: Enum.map(view.members, &%{"name" => &1.name, "role_note" => &1.role_note || ""})
    }
  end

  defp base(scope, gen, mode) do
    {leaders, humans, agents} = candidates(scope)

    %{
      mode: mode,
      gen: gen,
      name: nil,
      version: nil,
      errors: %{},
      member_errors: %{},
      members_error: [],
      error: nil,
      notice: nil,
      moved_leader: nil,
      leaders: leaders,
      humans: humans,
      agents: agents
    }
  end

  defp candidates(scope) do
    admin? = scope.role in [:owner, :admin]
    user_id = scope.user && scope.user.id
    agents = managed_agents(scope)

    leaders =
      for a <- agents do
        %{
          name: a.name,
          disabled: a.disabled,
          allowed?: admin? or a.owner.id == user_id,
          owner_name: a.owner.name
        }
      end

    {leaders, humans(scope), Enum.map(agents, & &1.name)}
  end

  defp managed_agents(scope) do
    case Agents.list(scope) do
      {:ok, list} -> Enum.filter(list, &(&1.kind == "managed" and not &1.archived))
      _ -> []
    end
  end

  defp humans(scope) do
    case Actors.list_assignable(scope) do
      {:ok, actors} -> for %{kind: :human, name: name} <- actors, do: name
      _ -> []
    end
  end

  ## Events

  def handle_event(event, params, %{assigns: %{squad_form: %{} = form}} = socket) do
    scope = socket.assigns.current_scope

    case event do
      "squad_form_change" ->
        {:noreply, put(socket, change(form, params))}

      "squad_form_move" ->
        {:noreply, put(socket, move(form, int(params["index"]), params["dir"]))}

      "squad_form_remove" ->
        {:noreply, put(socket, remove(form, int(params["index"])))}

      "squad_form_reload" ->
        {:noreply, put(socket, reload(form, scope))}

      "squad_form_submit" ->
        form = change(form, params)

        case submit(form, scope) do
          {:ok, view} -> {:saved, view, socket}
          {:error, :forbidden} -> {:forbidden, socket}
          {:error, form} -> {:noreply, put(socket, form)}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp put(socket, form), do: Phoenix.Component.assign(socket, :squad_form, form)

  defp int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> -1
    end
  end

  @doc "`phx-change`: keeps the input, adds the chosen member, moves a new leader out of the members."
  def change(form, params) do
    raw = params["squad"] || %{}
    form_params = Map.merge(form.params, Map.take(raw, ~w(name description instructions leader)))

    notes = raw["members"] || %{}

    members =
      form.members
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        case notes[to_string(i)] do
          %{"role_note" => note} -> %{m | "role_note" => note}
          _ -> m
        end
      end)

    members = add(members, raw["add"])
    leader = form_params["leader"]

    {members, moved} =
      if leader not in [nil, ""] and Enum.any?(members, &(&1["name"] == leader)),
        do: {Enum.reject(members, &(&1["name"] == leader)), leader},
        else: {members, form.moved_leader}

    %{form | params: form_params, members: members, moved_leader: moved}
  end

  defp add(members, name) when is_binary(name) and name != "" do
    if length(members) >= @max_members or Enum.any?(members, &(&1["name"] == name)),
      do: members,
      else: members ++ [%{"name" => name, "role_note" => ""}]
  end

  defp add(members, _name), do: members

  defp move(form, index, dir) do
    target = if dir == "up", do: index - 1, else: index + 1
    count = length(form.members)

    if index in 0..(count - 1)//1 and target in 0..(count - 1)//1 do
      a = Enum.at(form.members, index)
      b = Enum.at(form.members, target)

      members =
        form.members |> List.replace_at(index, b) |> List.replace_at(target, a)

      %{form | members: members}
    else
      form
    end
  end

  defp remove(form, index) do
    if index >= 0, do: %{form | members: List.delete_at(form.members, index)}, else: form
  end

  defp reload(%{mode: :edit, name: name} = form, scope) do
    case SquadData.get(scope, name) do
      {:ok, view} ->
        Map.merge(form, from_view(view))
        |> Map.merge(%{
          gen: form.gen + 1,
          notice: nil,
          errors: %{},
          member_errors: %{},
          members_error: []
        })

      _ ->
        form
    end
  end

  defp reload(form, _scope), do: form

  @doc "The attrs `SquadData.create/2` / `update/3` take."
  def attrs(form) do
    attrs = %{
      name: String.trim(form.params["name"] || ""),
      description: form.params["description"] || "",
      instructions: form.params["instructions"] || "",
      leader: blank_nil(form.params["leader"]),
      members: Enum.map(form.members, &%{name: &1["name"], role_note: &1["role_note"] || ""})
    }

    if form.mode == :edit, do: Map.put(attrs, :lock_version, form.version), else: attrs
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp submit(form, scope) do
    form = %{form | error: nil, notice: nil}

    result =
      case form.mode do
        :new -> SquadData.create(scope, attrs(form))
        :edit -> SquadData.update(scope, form.name, attrs(form))
      end

    case result do
      {:ok, view} ->
        {:ok, view}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, put_errors(form, FormErrors.messages(cs))}

      {:error, :stale} ->
        {:error, %{form | notice: :stale}}

      {:error, :forbidden} ->
        {:error, :forbidden}

      {:error, :not_found} ->
        {:error, %{form | error: dgettext("ui", "这个小队已不存在")}}
    end
  end

  @doc "Spreads the changeset messages; member messages go to the row of the name they start with."
  def put_errors(form, messages) do
    names = Enum.map(form.members, & &1["name"])

    {by_member, general} =
      messages
      |> Map.get(:members, [])
      |> Enum.reduce({%{}, []}, fn msg, {by, general} ->
        case Enum.find(names, &member_message?(msg, &1)) do
          nil -> {by, general ++ [msg]}
          name -> {Map.update(by, name, [msg], &(&1 ++ [msg])), general}
        end
      end)

    %{
      form
      | errors: Map.delete(messages, :members),
        member_errors: by_member,
        members_error: general
    }
  end

  defp member_message?(msg, name),
    do: String.starts_with?(msg, name <> " ") or String.starts_with?(msg, name <> ":")

  ## Rendering

  attr :form, :map, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, default: nil
  attr :on_cancel, JS, default: %JS{}

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="squad-panel"
      show={@form != nil}
      title={title(@form)}
      width={:wide}
      dirty={@form != nil}
      patch_on_close={@close_path}
      on_cancel={@on_cancel}
    >
      <:error :if={@form && @form.error}>{@form.error}</:error>
      <div
        :if={@form && @form.notice == :stale}
        id="squad-form-stale"
        role="status"
        class="mb-4 flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="size-4 shrink-0" />
        <span class="flex-1">{dgettext("ui", "这个小队刚被他人修改")}</span>
        <.button id="squad-form-reload" size="xs" phx-click="squad_form_reload">
          {dgettext("ui", "载入最新")}
        </.button>
      </div>
      <.squad_form :if={@form} form={@form} scope={@scope} />
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="squad-form-submit"
            type="submit"
            form="squad-form"
            variant="primary"
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {if(@form && @form.mode == :new, do: dgettext("ui", "创建"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp title(%{mode: :new}), do: dgettext("ui", "新建小队")
  defp title(%{mode: :edit, name: name}), do: dgettext("ui", "编辑 %{name}", name: name)
  defp title(_form), do: ""

  attr :form, :map, required: true
  attr :scope, :map, required: true

  defp squad_form(assigns) do
    form = assigns.form
    leader = form.params["leader"]
    taken = MapSet.new([leader | Enum.map(form.members, & &1["name"])])

    assigns =
      assign(assigns,
        p: form.params,
        e: form.errors,
        limits: limits(),
        leader_options: leader_options(form),
        add_options: add_options(form, taken),
        full?: length(form.members) >= @max_members,
        description_bytes: byte_size(form.params["description"] || ""),
        instructions_bytes: byte_size(form.params["instructions"] || "")
      )

    ~H"""
    <.form
      for={%{}}
      as={:squad}
      id="squad-form"
      phx-change="squad_form_change"
      phx-submit="squad_form_submit"
      class="flex flex-col gap-4"
    >
      <.input
        id="squad-form-name"
        name="squad[name]"
        label={dgettext("ui", "名字")}
        value={@p["name"]}
        errors={Map.get(@e, :name, [])}
        autocomplete="off"
      />
      <div class="flex flex-col gap-1">
        <.input
          id="squad-form-description"
          name="squad[description]"
          type="textarea"
          rows="2"
          label={dgettext("ui", "描述")}
          value={@p["description"]}
          errors={Map.get(@e, :description, [])}
        />
        <p
          id="squad-form-description-bytes"
          class={[
            "text-caption",
            if(@description_bytes > @limits.description, do: "text-danger-fg", else: "text-fg-subtle")
          ]}
        >
          {dgettext("ui", "%{n} / %{max} 字节", n: @description_bytes, max: @limits.description)}
        </p>
      </div>
      <div class="flex flex-col gap-1">
        <.input
          id="squad-form-leader"
          name="squad[leader]"
          type="select"
          label="Leader"
          prompt={dgettext("ui", "选择一个托管 Agent")}
          value={@p["leader"]}
          options={@leader_options}
          errors={Map.get(@e, :leader, [])}
        />
        <p class="text-caption text-fg-muted">
          {dgettext("ui", "Leader 收到交给小队的任务，决定谁来做、怎么拆；它不能创建 Agent")}
        </p>
        <p
          :if={@form.moved_leader}
          id="squad-form-leader-moved"
          role="status"
          class="text-caption text-warning-fg"
        >
          {dgettext("ui", "已把 %{name} 从成员中移除：它现在是 leader", name: @form.moved_leader)}
        </p>
      </div>

      <fieldset class="flex flex-col gap-2" id="squad-form-members">
        <legend class="mb-1 text-label font-medium text-fg">
          {dgettext("ui", "成员")}
          <span class="text-caption text-fg-subtle">
            {length(@form.members)} / {@limits.members}
          </span>
        </legend>
        <p
          :for={msg <- @form.members_error}
          class="flex items-center gap-1 text-caption text-danger-fg"
          data-members-error
        >
          <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
        </p>
        <p :if={@form.members == []} class="text-caption text-fg-subtle">
          {dgettext("ui", "还没有成员。成员可以是人或托管 Agent；同一个 CLI 可以有多个成员，各用不同的模型与指令")}
        </p>
        <ol class="flex flex-col gap-2">
          <li
            :for={{m, i} <- Enum.with_index(@form.members)}
            id={"squad-form-member-#{i}"}
            data-member={m["name"]}
            class="flex flex-col gap-1.5 rounded-field border border-border px-3 py-2"
          >
            <div class="flex items-center gap-2">
              <.actor_chip actor={%{name: m["name"], kind: member_kind(@form, m["name"])}} />
              <span class="flex-1" />
              <.icon_button
                id={"squad-form-member-#{i}-up"}
                size="xs"
                icon="lucide-arrow-up"
                disabled={i == 0}
                phx-click="squad_form_move"
                phx-value-index={i}
                phx-value-dir="up"
                label={dgettext("ui", "上移")}
              />
              <.icon_button
                id={"squad-form-member-#{i}-down"}
                size="xs"
                icon="lucide-arrow-down"
                disabled={i == length(@form.members) - 1}
                phx-click="squad_form_move"
                phx-value-index={i}
                phx-value-dir="down"
                label={dgettext("ui", "下移")}
              />
              <.icon_button
                id={"squad-form-member-#{i}-remove"}
                size="xs"
                icon="lucide-x"
                phx-click="squad_form_remove"
                phx-value-index={i}
                label={dgettext("ui", "移除")}
              />
            </div>
            <.input
              id={"squad-form-member-#{i}-note"}
              name={"squad[members][#{i}][role_note]"}
              value={m["role_note"]}
              placeholder={dgettext("ui", "擅长什么（给 leader 看），例如：写前端")}
              errors={Map.get(@form.member_errors, m["name"], [])}
              autocomplete="off"
            />
          </li>
        </ol>
        <.input
          id="squad-form-add"
          name="squad[add]"
          type="select"
          label={dgettext("ui", "添加成员")}
          prompt={
            if(@full?,
              do: dgettext("ui", "最多 %{n} 个成员", n: @limits.members),
              else: dgettext("ui", "选择人或托管 Agent")
            )
          }
          value=""
          options={@add_options}
          disabled={@full?}
        />
      </fieldset>

      <div class="flex flex-col gap-1">
        <.live_component
          module={MarkdownEditor}
          id={"squad-form-instructions-#{@form.gen}"}
          session={@form.gen}
          scope={@scope}
          name="squad[instructions]"
          value={@p["instructions"]}
          label={dgettext("ui", "说明（分工与工作方式）")}
          errors={Map.get(@e, :instructions, [])}
          submit={:form}
          rows={8}
        />
        <p
          id="squad-form-instructions-bytes"
          class={[
            "text-caption",
            if(@instructions_bytes > @limits.instructions,
              do: "text-danger-fg",
              else: "text-fg-subtle"
            )
          ]}
        >
          {dgettext("ui", "%{n} / %{max} 字节", n: @instructions_bytes, max: @limits.instructions)}
        </p>
      </div>
    </.form>
    """
  end

  defp member_kind(form, name), do: if(name in form.agents, do: :agent, else: :human)

  defp leader_options(form) do
    current = form.params["leader"]

    for l <- form.leaders do
      label =
        cond do
          not l.allowed? and l.name != current ->
            dgettext("ui", "%{name}（只能选你自己的 Agent 作为 leader）", name: l.name)

          l.disabled ->
            dgettext("ui", "%{name}（已停用）", name: l.name)

          true ->
            l.name
        end

      [key: label, value: l.name, disabled: not l.allowed? and l.name != current]
    end
  end

  defp add_options(form, taken) do
    humans = Enum.reject(form.humans, &MapSet.member?(taken, &1))
    agents = Enum.reject(form.agents, &MapSet.member?(taken, &1))

    [{dgettext("ui", "人"), humans}, {"Agent", agents}]
    |> Enum.reject(fn {_label, list} -> list == [] end)
  end
end

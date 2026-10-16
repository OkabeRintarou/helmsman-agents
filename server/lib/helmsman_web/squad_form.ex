defmodule HelmsmanWeb.SquadForm do
  @moduledoc """
  The squad side panel (add-squads-autopilots-ui D4): name, description, leader, an
  ordered member list with role notes, and instructions.

  Two forms: `:new` / `:edit` of a workspace squad, and `:draft` (D16) — the squad part
  of a creation conversation's draft, whose submit the conversation page handles
  (`draft_attrs/1`, `AgentDesigns.put_squad/4`).

  The form is a map in the page's `:squad_form` assign; the page routes the
  `squad_form_*` events to `handle_event/3`, which returns `{:saved, view, socket}`,
  `{:forbidden, socket}` or `{:noreply, socket}`.

  Leader candidates are the workspace's unarchived managed agents; a member may only pick
  their own (admins any). Member candidates are the workspace's humans and unarchived
  managed agents other than the leader. Member errors of the domain start with the
  member's name (domain-request-1 R3) and are shown on that member's row.

  In `:draft` the draft's new agents come first among the leader and member candidates
  (marked 新) and the leader's owner is not checked: the domain checks it on
  confirmation.
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
      params: %{
        "name" => "",
        "description" => "",
        "instructions" => "",
        "leader" => "",
        "spec_finalize" => ""
      },
      members: []
    })
  end

  @doc "A form editing the squad `view` (`SquadData.get/2`)."
  def edit(scope, gen, view) do
    base(scope, gen, :edit)
    |> Map.merge(from_view(view))
  end

  @doc """
  A form editing the squad part of the conversation draft of `design` (an
  `AgentDesigns` view of a `squad` conversation), with the field `errors` of a refused
  confirmation (`%{field => [message]}`). A `squad_edit` conversation
  (add-edit-design-conversations D14) has its name fixed and each field that differs
  from its baseline gets 「恢复为当前配置」 (`squad_form_revert`).
  """
  def draft(scope, gen, design, errors \\ %{}) do
    squad = draft_squad(design.draft)

    form = base(scope, gen, :draft, new_names(design.draft))

    baseline =
      case design do
        %{kind: :squad_edit, baseline: %{"squad" => b}} -> Map.put(b, "name", squad["name"])
        _other -> nil
      end

    form
    |> Map.merge(canonical(form, from_squad(squad)))
    |> Map.merge(%{
      version: design.draft_version,
      base: squad,
      lock_name?: baseline != nil,
      baseline: baseline
    })
    |> put_errors(errors || %{})
  end

  @doc "The fields of a `squad_edit` form that differ from its baseline."
  def reverts(%{baseline: %{} = baseline} = form) do
    old = canonical(form, from_squad(baseline))
    now = %{params: form.params, members: form.members}

    Enum.filter(~w(description instructions leader members), fn
      "members" -> not same?("members", now.members, old.members)
      field -> not same?(field, now.params[field], old.params[field])
    end)
  end

  def reverts(_form), do: []

  defp revert(%{baseline: %{} = baseline} = form, field) do
    old = canonical(form, from_squad(baseline))

    cond do
      field not in reverts(form) -> form
      field == "members" -> %{form | members: old.members}
      true -> %{form | params: Map.put(form.params, field, old.params[field])}
    end
  end

  defp revert(form, _field), do: form

  # The domain resolves the squad's names case-insensitively (the draft's agents first,
  # then the workspace's identities): a reference is shown as the candidate it resolves
  # to, so the leader select keeps its option selected (code-review-7 P2-2).
  defp canonical(form, %{params: params, members: members}) do
    %{
      params: Map.update!(params, "leader", &candidate(form, &1)),
      members: Enum.map(members, &Map.update!(&1, "name", fn name -> candidate(form, name) end))
    }
  end

  defp candidate(_form, name) when name in [nil, ""], do: name

  defp candidate(form, name) do
    key = key(name)
    Enum.find(form.agents ++ form.humans, name, &(key(&1) == key))
  end

  defp key(name) when is_binary(name), do: String.downcase(name)
  defp key(_name), do: nil

  @doc "The squad part of a draft (the empty one when absent)."
  def draft_squad(%{"squad" => %{} = squad}), do: squad

  def draft_squad(_draft),
    do: %{
      "name" => nil,
      "description" => "",
      "leader" => nil,
      "instructions" => "",
      "members" => []
    }

  defp new_names(draft) do
    for %{"name" => name} <- List.wrap(draft["agents"]), is_binary(name), do: name
  end

  defp from_squad(squad) do
    %{
      params: %{
        "name" => squad["name"] || "",
        "description" => squad["description"] || "",
        "instructions" => squad["instructions"] || "",
        "leader" => squad["leader"] || ""
      },
      members:
        for(
          %{"name" => name} = m <- List.wrap(squad["members"]),
          do: %{"name" => name, "role_note" => m["role_note"] || ""}
        )
    }
  end

  @doc """
  The open `:draft` form after the draft changed: new candidates (the draft's agents),
  the input kept.
  """
  def refresh(%{mode: :draft} = form, scope, draft) do
    fresh = base(scope, form.gen, :draft, new_names(draft))
    form = Map.merge(form, Map.take(fresh, [:leaders, :humans, :agents, :new]))
    Map.merge(form, canonical(form, Map.take(form, [:params, :members])))
  end

  def refresh(form, _scope, _draft), do: form

  @doc """
  A `stale` save of the `:draft` form (D16, as the agent draft panel): the latest squad
  part is loaded, the fields the user changed since opening keep the input.
  """
  def rebase(%{mode: :draft} = form, scope, design) do
    squad = draft_squad(design.draft)
    form = refresh(form, scope, design.draft)
    old = canonical(form, from_squad(form.base))
    fresh = canonical(form, from_squad(squad))

    params =
      Map.new(form.params, fn {k, v} ->
        if same?(k, v, old.params[k]), do: {k, fresh.params[k]}, else: {k, v}
      end)

    members =
      if same?("members", form.members, old.members), do: fresh.members, else: form.members

    form
    |> Map.merge(%{
      params: params,
      members: members,
      base: squad,
      version: design.draft_version,
      gen: form.gen + 1,
      notice: :draft_stale,
      error: nil
    })
  end

  @doc """
  The attrs of `AgentDesigns.put_squad/4` (string keys; a blank name or leader is nil):
  only the fields that differ from the squad part the panel was opened on (`base`), names
  compared case-insensitively — an untouched `WEB-LEAD` stays as the AI wrote it.
  """
  def draft_attrs(form) do
    attrs = put_squad_attrs(form)

    case form.base do
      nil ->
        attrs

      base ->
        old = put_squad_attrs(from_squad(base))
        Map.reject(attrs, fn {k, v} -> same?(k, v, old[k]) end)
    end
  end

  defp put_squad_attrs(%{params: params, members: members}) do
    %{
      "name" => blank_nil(String.trim(params["name"] || "")),
      "description" => params["description"] || "",
      "instructions" => params["instructions"] || "",
      "leader" => blank_nil(params["leader"] || ""),
      "members" =>
        Enum.map(members, &%{"name" => &1["name"], "role_note" => &1["role_note"] || ""})
    }
  end

  defp same?("leader", a, b), do: key(blank_nil(a || "")) == key(blank_nil(b || ""))

  defp same?("members", a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.all?(Enum.zip(a, b), fn {x, y} ->
        key(x["name"]) == key(y["name"]) and (x["role_note"] || "") == (y["role_note"] || "")
      end)
  end

  defp same?(_field, a, b), do: a == b

  defp from_view(view) do
    %{
      name: view.name,
      version: view.lock_version,
      params: %{
        "name" => view.name,
        "description" => view.description || "",
        "instructions" => view.instructions || "",
        "leader" => view.leader.name,
        "spec_finalize" => spec_finalize_value(Map.get(view, :spec_finalize))
      },
      spec_finalize_base: spec_finalize_value(Map.get(view, :spec_finalize)),
      members: Enum.map(view.members, &%{"name" => &1.name, "role_note" => &1.role_note || ""})
    }
  end

  defp spec_finalize_value(nil), do: ""
  defp spec_finalize_value(value), do: to_string(value)

  defp base(scope, gen, mode, new \\ []) do
    {leaders, humans, agents} = candidates(scope, mode, new)

    %{
      mode: mode,
      gen: gen,
      admin?: scope.role in [:owner, :admin],
      spec_finalize_base: "",
      name: nil,
      version: nil,
      base: nil,
      new: new,
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

  defp candidates(scope, mode, new) do
    admin? = scope.role in [:owner, :admin]
    user_id = scope.user && scope.user.id
    new_keys = MapSet.new(new, &String.downcase/1)

    # A draft agent shadows a workspace agent of the same name (the domain resolves
    # names to the draft first).
    agents =
      scope
      |> managed_agents()
      |> Enum.reject(&MapSet.member?(new_keys, String.downcase(&1.name)))

    drafted =
      for name <- new,
          do: %{name: name, disabled: false, allowed?: true, owner_name: nil, new?: true}

    leaders =
      for a <- agents do
        %{
          name: a.name,
          disabled: a.disabled,
          allowed?: mode == :draft or admin? or a.owner.id == user_id,
          owner_name: a.owner.name,
          new?: false
        }
      end

    {drafted ++ leaders, humans(scope), new ++ Enum.map(agents, & &1.name)}
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

  def handle_event("squad_form_revert", params, %{assigns: %{squad_form: %{} = form}} = socket),
    do: {:noreply, put(socket, revert(form, params["field"]))}

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

    form_params =
      form.params
      |> Map.merge(Map.take(raw, ~w(name description instructions leader)))
      |> Map.merge(spec_finalize_change(form, raw["spec_finalize"]))

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
      if leader not in [nil, ""] and Enum.any?(members, &(key(&1["name"]) == key(leader))),
        do: {Enum.reject(members, &(key(&1["name"]) == key(leader))), leader},
        else: {members, form.moved_leader}

    %{form | params: form_params, members: members, moved_leader: moved}
  end

  defp add(members, name) when is_binary(name) and name != "" do
    if length(members) >= @max_members or Enum.any?(members, &(key(&1["name"]) == key(name))),
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

    attrs = if form.mode == :edit, do: Map.put(attrs, :lock_version, form.version), else: attrs

    # 规格定稿方式 (add-spec-workflow-ui D17) only when it changed: a non-admin saving
    # a `leader` squad leaves it alone.
    case form.params["spec_finalize"] do
      value when value in [nil, form.spec_finalize_base] -> attrs
      "" -> Map.put(attrs, :spec_finalize, nil)
      value -> Map.put(attrs, :spec_finalize, value)
    end
  end

  # Only admins may choose `leader` (unless it is already the value).
  defp spec_finalize_change(_form, nil), do: %{}

  defp spec_finalize_change(form, value) do
    cond do
      value not in ["", "approval", "leader"] -> %{}
      value == "leader" and not leader_choosable?(form) -> %{}
      true -> %{"spec_finalize" => value}
    end
  end

  @doc "Whether the 规格定稿方式 `leader` may be chosen in `form`."
  def leader_choosable?(form), do: form.admin? or form.params["spec_finalize"] == "leader"

  defp spec_finalize_admin_only, do: dgettext("ui", "只有管理员可以设为 Leader 定稿")

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
        if Map.has_key?(attrs(form), :spec_finalize),
          do:
            {:error,
             %{form | errors: Map.put(form.errors, :spec_finalize, [spec_finalize_admin_only()])}},
          else: {:error, :forbidden}

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

  @doc """
  `put_errors/2` for a changeset of the conversation domain: a member error goes to the
  row of its `name` option, else of the name it starts with.
  """
  def put_changeset(form, %Ecto.Changeset{errors: errors} = cs) do
    {members, other} = Enum.split_with(errors, &match?({:members, _}, &1))
    form = put_errors(form, FormErrors.messages(%{cs | errors: other}))

    Enum.reduce(members, form, fn {:members, {_msg, opts}} = error, form ->
      [text] = FormErrors.messages(%{cs | errors: [error]}).members

      case member_row(form, opts[:name], text) do
        nil ->
          %{form | members_error: form.members_error ++ [text]}

        name ->
          %{form | member_errors: Map.update(form.member_errors, name, [text], &(&1 ++ [text]))}
      end
    end)
  end

  defp member_row(form, name, text) do
    names = Enum.map(form.members, & &1["name"])

    if is_binary(name) do
      key = String.downcase(name)
      Enum.find(names, &(String.downcase(&1) == key))
    else
      Enum.find(names, &member_message?(text, &1))
    end
  end

  defp member_message?(msg, name),
    do: String.starts_with?(msg, name <> " ") or String.starts_with?(msg, name <> ":")

  ## Rendering

  attr :form, :map, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  attr :locked, :string, default: nil, doc: "why saving a `:draft` form is unavailable now"
  attr :appearance, :map, default: %{}, doc: "the shell's `@appearance` (member marks)"

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
      <div
        :if={@form && @form.notice == :draft_stale}
        id="squad-form-notice"
        role="status"
        class="mb-4 flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
        {dgettext("ui", "草稿刚被更新（可能是 AI 或另一个标签页），已载入最新内容，你改过的字段保留")}
      </div>
      <div
        :if={@locked}
        id="squad-form-locked-notice"
        role="status"
        class="mb-4 flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-hourglass" class="mt-0.5 size-4 shrink-0" />
        {@locked}
      </div>
      <div
        :if={@form && reverts(@form) != []}
        id="squad-form-reverts"
        class="mb-4 flex flex-col gap-1 rounded-field border border-border bg-surface px-3 py-2"
      >
        <p class="text-caption text-fg-muted">{dgettext("ui", "与当前配置不同的字段")}</p>
        <div :for={field <- reverts(@form)} class="flex items-center justify-between gap-2">
          <span class="text-body text-fg">{HelmsmanWeb.AgentDesignSquad.field_label(field)}</span>
          <.button
            id={"squad-form-revert-#{field}"}
            size="xs"
            variant="ghost"
            phx-click="squad_form_revert"
            phx-value-field={field}
          >
            {dgettext("ui", "恢复为当前配置")}
          </.button>
        </div>
      </div>
      <.squad_form :if={@form} form={@form} scope={@scope} appearance={@appearance} />
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="squad-form-submit"
            type="submit"
            form="squad-form"
            variant="primary"
            disabled={@locked != nil}
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {submit_label(@form)}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp submit_label(%{mode: :new}), do: dgettext("ui", "创建")
  defp submit_label(%{mode: :draft}), do: dgettext("ui", "保存到草稿")
  defp submit_label(_form), do: dgettext("ui", "保存")

  defp title(%{mode: :new}), do: dgettext("ui", "新建小队")
  defp title(%{mode: :draft}), do: dgettext("ui", "编辑小队")
  defp title(%{mode: :edit, name: name}), do: dgettext("ui", "编辑 %{name}", name: name)
  defp title(_form), do: ""

  attr :form, :map, required: true
  attr :scope, :map, required: true
  attr :appearance, :map, default: %{}

  defp squad_form(assigns) do
    form = assigns.form
    leader = form.params["leader"]
    taken = MapSet.new([leader | Enum.map(form.members, & &1["name"])], &key/1)

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
        disabled={@form[:lock_name?] == true}
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
      <div :if={@form.mode != :draft} class="flex flex-col gap-1" id="squad-form-spec-finalize">
        <label for="squad-form-spec-finalize-select" class="text-label font-medium text-fg">
          {dgettext("ui", "规格定稿方式")}
        </label>
        <select
          id="squad-form-spec-finalize-select"
          name="squad[spec_finalize]"
          class="h-9 rounded-field border border-border bg-surface px-2 text-body"
        >
          <option value="" selected={@p["spec_finalize"] == ""}>{dgettext("ui", "继承项目")}</option>
          <option value="approval" selected={@p["spec_finalize"] == "approval"}>
            {dgettext("ui", "需要人批准")}
          </option>
          <option
            value="leader"
            selected={@p["spec_finalize"] == "leader"}
            disabled={!leader_choosable?(@form)}
          >
            {dgettext("ui", "Leader 定稿")}
          </option>
        </select>
        <p :if={!@form.admin?} id="squad-form-spec-finalize-help" class="text-caption text-fg-subtle">
          {spec_finalize_admin_only()}
        </p>
        <p :for={e <- Map.get(@e, :spec_finalize, [])} class="text-caption text-danger-fg" data-error>
          {e}
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
        <p :if={@form.mode == :draft} id="squad-form-leader-draft" class="text-caption text-fg-muted">
          {dgettext(
            "ui",
            "可以选草稿里的新 Agent 或工作区已有的托管 Agent；确认创建时检查你能否把它设为 leader"
          )}
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
              <.actor_chip actor={
                Appearance.decorate(
                  %{name: m["name"], kind: member_kind(@form, m["name"])},
                  @appearance
                )
              } />
              <.badge
                :if={@form.mode == :draft and new?(@form, m["name"])}
                tone={:brand}
                data-origin="new"
              >
                {dgettext("ui", "新")}
              </.badge>
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

  defp member_kind(form, name),
    do: if(Enum.any?(form.agents, &(key(&1) == key(name))), do: :agent, else: :human)

  defp new?(form, name), do: Enum.any?(form.new, &(key(&1) == key(name)))

  defp leader_options(form) do
    current = form.params["leader"]

    for l <- form.leaders do
      label =
        cond do
          l.new? ->
            dgettext("ui", "%{name}（新）", name: l.name)

          not l.allowed? and l.name != current ->
            dgettext("ui", "%{name}（只能选你自己的 Agent 作为 leader）", name: l.name)

          l.disabled ->
            dgettext("ui", "%{name}（已停用）", name: l.name)

          true ->
            l.name
        end

      [key: label, value: l.name, disabled: not l.allowed? and l.name != current]
    end
    |> keep_current(form, current)
  end

  # A current leader that is no candidate (archived meanwhile, unknown) keeps an option of
  # its own: the select must not fall back to the prompt and clear it on submit.
  defp keep_current(options, _form, current) when current in [nil, ""], do: options

  defp keep_current(options, form, current) do
    if Enum.any?(form.leaders, &(key(&1.name) == key(current))),
      do: options,
      else: [[key: dgettext("ui", "%{name}（当前，不在候选中）", name: current), value: current] | options]
  end

  defp add_options(form, taken) do
    humans = Enum.reject(form.humans, &MapSet.member?(taken, key(&1)))

    agents =
      for name <- form.agents, not MapSet.member?(taken, key(name)) do
        if new?(form, name),
          do: [key: dgettext("ui", "%{name}（新）", name: name), value: name],
          else: name
      end

    [{dgettext("ui", "人"), humans}, {"Agent", agents}]
    |> Enum.reject(fn {_label, list} -> list == [] end)
  end
end

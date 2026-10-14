defmodule HelmsmanWeb.AgentDesignSquad do
  @moduledoc """
  The squad part of a `squad` creation conversation (add-squads-autopilots-ui D16): the
  squad block above the draft cards, its texts and the squad row of the confirmation
  dialog. The draft's squad is `draft["squad"]` (`%{"name", "description", "leader",
  "instructions", "members" => [%{"name", "role_note"}], "updated_by"}`); names resolve
  to the draft's new agents first (case-insensitive), then to the workspace's
  identities, as the domain does.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentDesignComponents, only: [byte_text: 1]

  alias HelmsmanWeb.SquadComponents

  @doc "Whether the conversation view designs a squad."
  def squad?(%{kind: kind}), do: kind in [:squad, "squad"]
  def squad?(_design), do: false

  @doc "The squad part of a draft, nil without one."
  def squad(%{"squad" => %{} = squad}), do: squad
  def squad(_draft), do: nil

  @doc "The name as shown: 「未命名」 while empty."
  def display_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  def display_name(_squad), do: dgettext("ui", "未命名")

  @doc "What the squad still needs before it can be confirmed: `[:name, :leader]` or less."
  def missing(nil), do: []

  def missing(squad) do
    for field <- [:name, :leader], blank?(squad[Atom.to_string(field)]), do: field
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  @doc "「小队还缺名字 / leader，补齐后才能确认」, nil when complete."
  def missing_text([]), do: nil

  def missing_text(fields) do
    labels = Enum.map_join(fields, " / ", &field_label/1)
    dgettext("ui", "小队还缺%{fields}，补齐后才能确认", fields: labels)
  end

  @doc "The localized name of a squad draft field (pending edits, errors)."
  def field_label(field) when is_atom(field), do: field_label(Atom.to_string(field))
  def field_label("name"), do: dgettext("ui", "名字")
  def field_label("description"), do: dgettext("ui", "描述")
  def field_label("leader"), do: "leader"
  def field_label("instructions"), do: dgettext("ui", "说明")
  def field_label("members"), do: dgettext("ui", "成员")
  def field_label(field), do: field

  @doc "Whether the squad part refers to `name` (as leader or member)."
  def references?(draft, name) when is_binary(name) do
    case squad(draft) do
      nil ->
        false

      squad ->
        key = String.downcase(name)

        [squad["leader"] | Enum.map(List.wrap(squad["members"]), & &1["name"])]
        |> Enum.any?(&(is_binary(&1) and String.downcase(&1) == key))
    end
  end

  def references?(_draft, _name), do: false

  @doc "「先在小队里移除 <名字>」: why a draft agent the squad refers to cannot be removed."
  def referenced_text(name), do: dgettext("ui", "先在小队里移除 %{name}", name: name)

  @doc "The lower-cased names of the draft's new agents."
  def new_keys(draft) do
    for %{"name" => name} <- List.wrap(draft["agents"]),
        is_binary(name),
        into: MapSet.new(),
        do: String.downcase(name)
  end

  defp new?(keys, name), do: is_binary(name) and MapSet.member?(keys, String.downcase(name))

  ## The squad block (D16)

  attr :design, :map, required: true, doc: "the conversation view (`kind: :squad`)"
  attr :humans, :any, required: true, doc: "MapSet of the workspace's people, lower-cased"
  attr :errors, :map, default: nil, doc: "%{field => [message]} of a refused confirmation"
  attr :locked, :string, default: nil, doc: "why the squad cannot be edited now"
  attr :scope, :map, required: true
  attr :appearance, :map, default: %{}, doc: "the shell's `@appearance`"

  def block(assigns) do
    squad = squad(assigns.design.draft) || %{}
    keys = new_keys(assigns.design.draft)
    errors = assigns.errors || %{}

    assigns =
      assign(assigns,
        squad: squad,
        keys: keys,
        e: errors,
        missing: missing_text(missing(squad)),
        members: List.wrap(squad["members"]),
        size: byte_text(byte_size(squad["instructions"] || ""))
      )

    ~H"""
    <section
      id="design-squad"
      aria-label={dgettext("ui", "小队")}
      data-name={@squad["name"]}
      class={[
        "flex min-w-0 flex-col gap-2 rounded-box border bg-surface p-3",
        if(@e != %{}, do: "border-danger", else: "border-border")
      ]}
    >
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <.actor_mark actor={Appearance.decorate(%{name: @squad["name"], kind: :squad}, @appearance)} />
        <span
          class={[
            "min-w-0 truncate text-body font-semibold",
            if(@squad["name"] in [nil, ""], do: "text-fg-muted", else: "font-mono text-fg")
          ]}
          data-field="name"
        >
          {display_name(@squad)}
        </span>
        <.badge tone={:muted}>{dgettext("ui", "小队")}</.badge>
        <.badge :if={@squad["updated_by"] == "ai"} tone={:info} data-updated-by="ai">
          {dgettext("ui", "AI 修改")}
        </.badge>
        <.badge :if={@squad["updated_by"] == "user"} tone={:brand} data-updated-by="user">
          {dgettext("ui", "你修改")}
        </.badge>
        <.button
          id="design-squad-edit"
          size="xs"
          variant="ghost"
          icon="lucide-pencil"
          class="ml-auto"
          phx-click="edit_squad"
          disabled_reason={@locked}
        >
          {dgettext("ui", "编辑小队")}
        </.button>
      </div>

      <p
        :if={@missing}
        id="design-squad-missing"
        role="note"
        class="rounded-field border border-warning tint-warning px-2 py-1 text-caption text-warning-fg"
      >
        {@missing}
      </p>

      <.field_errors id="design-squad-name-errors" messages={Map.get(@e, :name, [])} />

      <p
        :if={(@squad["description"] || "") != ""}
        class="text-body text-fg-muted"
        data-field="description"
      >
        {@squad["description"]}
      </p>
      <.field_errors messages={Map.get(@e, :description, [])} />

      <.property_list>
        <.property_row label="Leader" data-field="leader">
          <span :if={@squad["leader"] in [nil, ""]} class="text-fg-muted">
            {dgettext("ui", "未选")}
          </span>
          <span :if={@squad["leader"] not in [nil, ""]} class="flex min-w-0 items-center gap-1.5">
            <.actor_chip actor={
              Appearance.decorate(%{name: @squad["leader"], kind: :agent}, @appearance)
            } />
            <.origin new={new?(@keys, @squad["leader"])} />
          </span>
        </.property_row>
      </.property_list>
      <.field_errors id="design-squad-leader-errors" messages={Map.get(@e, :leader, [])} />

      <div class="flex flex-col gap-1" data-field="members">
        <p class="text-label font-medium text-fg-muted">
          {dgettext("ui", "成员")}
          <span class="tabular-nums">{length(@members)}</span>
        </p>
        <.field_errors id="design-squad-members-errors" messages={Map.get(@e, :members, [])} />
        <p :if={@members == []} class="text-caption text-fg-subtle">
          {dgettext("ui", "还没有成员")}
        </p>
        <ol :if={@members != []} id="design-squad-members" class="flex flex-col gap-1.5">
          <li
            :for={{m, i} <- Enum.with_index(@members)}
            id={"design-squad-member-#{i}"}
            data-member={m["name"]}
            class="flex min-w-0 flex-col gap-0.5"
          >
            <span class="flex min-w-0 flex-wrap items-center gap-1.5">
              <.actor_chip actor={
                Appearance.decorate(
                  %{name: m["name"], kind: member_kind(m["name"], @keys, @humans)},
                  @appearance
                )
              } />
              <span class="text-caption text-fg-muted" data-kind>
                {kind_label(member_kind(m["name"], @keys, @humans))}
              </span>
              <.origin new={new?(@keys, m["name"])} />
            </span>
            <span
              :if={(m["role_note"] || "") != ""}
              class="pl-6 text-caption text-fg-muted"
              data-role-note
            >
              {m["role_note"]}
            </span>
          </li>
        </ol>
      </div>

      <div
        :if={@design[:trigger_summary]}
        id="design-squad-trigger-box"
        class={[
          "rounded-field border px-2 py-1.5",
          if(@design.trigger_summary.restricted != [],
            do: "border-warning tint-warning",
            else: "border-border"
          )
        ]}
        data-warn={@design.trigger_summary.restricted != [] && "restricted"}
      >
        <SquadComponents.trigger_summary id="design-squad-trigger" summary={@design.trigger_summary} />
      </div>

      <details :if={(@squad["instructions"] || "") != ""} data-field="instructions">
        <summary class="cursor-pointer text-label text-fg-muted">
          {dgettext("ui", "说明（%{size}）", size: @size)}
        </summary>
        <div class="mt-2 border-t border-border pt-2">
          <.markdown content={@squad["instructions"]} scope={@scope} anchor_ns="design-squad" />
        </div>
      </details>
      <.field_errors messages={Map.get(@e, :instructions, [])} />
    </section>
    """
  end

  attr :id, :string, default: nil
  attr :messages, :list, required: true

  defp field_errors(assigns) do
    ~H"""
    <ul :if={@messages != []} id={@id} role="alert" class="flex flex-col text-caption text-danger-fg">
      <li :for={msg <- @messages} data-error>{msg}</li>
    </ul>
    """
  end

  attr :new, :boolean, required: true

  defp origin(assigns) do
    ~H"""
    <.badge :if={@new} tone={:brand} data-origin="new">{dgettext("ui", "新")}</.badge>
    <.badge :if={!@new} tone={:muted} data-origin="existing">{dgettext("ui", "已有")}</.badge>
    """
  end

  defp member_kind(name, keys, humans) do
    cond do
      new?(keys, name) -> :agent
      is_binary(name) and MapSet.member?(humans, String.downcase(name)) -> :human
      true -> :agent
    end
  end

  defp kind_label(:human), do: dgettext("ui", "人")
  defp kind_label(_kind), do: dgettext("ui", "托管 Agent")

  ## Confirmation (D16)

  attr :squad, :map, required: true
  attr :summary, :map, default: nil
  attr :keys, :any, required: true, doc: "lower-cased names of the draft's new agents"
  attr :appearance, :map, default: %{}, doc: "the shell's `@appearance`"

  @doc "The squad row in front of the confirmation dialog's list."
  def confirm_row(assigns) do
    assigns = assign(assigns, :members, List.wrap(assigns.squad["members"]))

    ~H"""
    <div
      id="design-confirm-squad"
      data-name={@squad["name"]}
      class="flex flex-col gap-1 rounded-field border border-border px-3 py-2"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.actor_mark actor={Appearance.decorate(%{name: @squad["name"], kind: :squad}, @appearance)} />
        <span class="font-mono text-body font-semibold text-fg">{@squad["name"]}</span>
        <span class="text-caption text-fg-muted" data-leader={@squad["leader"]}>
          {dgettext("ui", "leader %{name}", name: @squad["leader"])}
          <span :if={new?(@keys, @squad["leader"])}>{dgettext("ui", "（新）")}</span>
        </span>
        <span class="text-caption text-fg-muted" data-members={length(@members)}>
          {dngettext("ui", "%{count} 个成员", "%{count} 个成员", length(@members))}
        </span>
      </div>
      <p
        :if={@summary}
        class={[
          "flex flex-wrap items-center gap-1 text-caption",
          if(@summary.restricted != [], do: "text-warning-fg", else: "text-fg-muted")
        ]}
        data-warn={@summary.restricted != [] && "restricted"}
      >
        <.icon :if={@summary.restricted != []} name="lucide-triangle-alert" class="size-3.5" />
        {dgettext("ui", "能触发这个小队的成员 %{able} / %{total}",
          able: @summary.able,
          total: @summary.total
        )}
        <span :if={@summary.restricted != []}>
          {dgettext("ui", "（受限：%{names}）", names: Enum.join(@summary.restricted, "、"))}
        </span>
      </p>
    </div>
    """
  end
end

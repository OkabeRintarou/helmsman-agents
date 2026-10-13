defmodule HelmsmanWeb.SquadComponents do
  @moduledoc """
  Pieces of the squad pages (add-squads-autopilots-ui D2, D3, D6): availability texts,
  the 可触发 summary, member stacks and an agent's CLI · 模型 · 推理强度 line.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]

  @doc """
  Why the current user cannot trigger squad `name`, from `HelmsmanWeb.SquadData.availability/1`;
  `nil` for `:ok` or no entry.
  """
  def unavailable_reason(_name, nil), do: nil
  def unavailable_reason(_name, :ok), do: nil

  def unavailable_reason(_name, {:skipped, :unauthorized, refused}) when refused not in [nil, []],
    do: dgettext("ui", "你无权触发 %{names}", names: Enum.join(refused, "、"))

  def unavailable_reason(name, {:skipped, :unauthorized, _}),
    do: dgettext("ui", "你无权触发 %{name}", name: name)

  def unavailable_reason(_name, {:skipped, :squad_disabled, _}), do: dgettext("ui", "小队已停用")
  def unavailable_reason(_name, {:skipped, :agent_archived, _}), do: dgettext("ui", "leader 已归档")
  def unavailable_reason(_name, {:skipped, :agent_disabled, _}), do: dgettext("ui", "leader 已停用")

  def unavailable_reason(_name, {:skipped, :not_managed, _}),
    do: dgettext("ui", "leader 不是托管 Agent")

  def unavailable_reason(name, {:skipped, _reason, _}),
    do: dgettext("ui", "不能触发 %{name}", name: name)

  @doc "The refused names of an availability entry (`[]` otherwise)."
  def refused({:skipped, :unauthorized, refused}) when is_list(refused), do: refused
  def refused(_entry), do: []

  @doc "「Claude Code · sonnet · high」 of an agent (缺省 values say so)."
  def config_line(%{provider: nil}), do: nil

  def config_line(%{provider: provider} = agent) do
    [
      provider_label(provider),
      agent[:model] || dgettext("ui", "CLI 缺省模型"),
      agent[:effort] || dgettext("ui", "缺省推理强度")
    ]
    |> Enum.join(" · ")
  end

  def config_line(_agent), do: nil

  @doc "「能触发这个小队的成员 N / M」 with the restricted members and why it matters."
  attr :id, :string, required: true
  attr :summary, :map, default: nil

  def trigger_summary(%{summary: nil} = assigns), do: ~H""

  def trigger_summary(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-1.5" data-trigger-summary>
      <p class={[
        "text-body",
        if(@summary.able < @summary.total, do: "text-warning-fg", else: "text-fg")
      ]}>
        {dgettext("ui", "能触发这个小队的成员 %{able} / %{total}",
          able: @summary.able,
          total: @summary.total
        )}
      </p>
      <div :if={@summary.restricted != []} class="flex flex-col gap-1" data-restricted>
        <p class="flex flex-wrap items-center gap-1 text-caption text-fg-muted">
          <.icon name="lucide-triangle-alert" class="size-3.5 text-warning" />
          <span :for={name <- @summary.restricted} class="font-medium text-fg">{name}</span>
        </p>
        <p class="text-caption text-fg-muted">
          {dgettext(
            "ui",
            "这些成员只允许所属用户（或指定成员）触发，工作区里多数人因此无法触发这个小队"
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc "The first members as icons plus「n 个成员」."
  attr :members, :list, required: true
  attr :max, :integer, default: 5

  def member_stack(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2" data-members>
      <span class="inline-flex -space-x-1">
        <.actor_chip
          :for={m <- Enum.take(@members, @max)}
          actor={%{name: m.name, kind: m.kind}}
          compact
        />
      </span>
      <span class="text-fg-muted">
        {dngettext("ui", "%{count} 个成员", "%{count} 个成员", length(@members))}
      </span>
    </span>
    """
  end

  @doc "A squad as an `actor_chip` linking to its page."
  attr :slug, :string, required: true
  attr :name, :string, required: true
  attr :class, :any, default: nil

  def squad_link(assigns) do
    ~H"""
    <.link
      navigate={HelmsmanWeb.Url.squad_path(@slug, @name)}
      class={["min-w-0", @class]}
      data-squad-link
    >
      <.actor_chip actor={%{name: @name, kind: :squad}} />
    </.link>
    """
  end
end

defmodule HelmsmanWeb.AgentComponents do
  @moduledoc """
  Agent pieces (add-agents-runs-ui D2, D3): the CLI (provider) label with a neutral
  terminal icon (no third-party marks, web-visual-system「图标集与第三方商标」) and the
  runtime status.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1]
  import HelmsmanWeb.Components.Actor, only: [presence_dot: 1]
  import HelmsmanWeb.Components.Status, only: [badge: 1]

  @providers ~w(claude codex copilot cursor)

  @doc "The CLIs a managed agent can use."
  def providers, do: @providers

  @doc "Display name of a CLI."
  def provider_label("claude"), do: "Claude Code"
  def provider_label("codex"), do: "Codex"
  def provider_label("copilot"), do: "Copilot CLI"
  def provider_label("cursor"), do: "Cursor CLI"
  def provider_label(nil), do: ""
  def provider_label(other), do: to_string(other)

  @doc "CLI icon and name."
  attr :provider, :string, required: true
  attr :class, :any, default: nil

  def provider(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]} data-provider={@provider}>
      <.icon name="lucide-square-terminal" class="size-4 text-fg-muted" />
      <span class="truncate">{provider_label(@provider)}</span>
    </span>
    """
  end

  @doc "Status of a runtime view: `:disabled`, `:unavailable`, `:online` or `:offline`."
  def runtime_status(%{disabled: true}), do: :disabled
  def runtime_status(%{unavailable_reason: reason}) when is_binary(reason), do: :unavailable
  def runtime_status(%{status: "online"}), do: :online
  def runtime_status(_runtime), do: :offline

  @doc "Badge of `runtime_status/1`, with the reason of an unavailable runtime."
  attr :runtime, :map, required: true
  attr :id, :string, default: nil

  def runtime_badge(assigns) do
    assigns = assign(assigns, :status, runtime_status(assigns.runtime))

    ~H"""
    <span id={@id} data-runtime-status={@status} class="inline-flex min-w-0 items-center gap-1.5">
      <%= case @status do %>
        <% :online -> %>
          <.presence_dot status={:online} />
          <span class="text-success-fg">{dgettext("ui", "在线")}</span>
        <% :offline -> %>
          <.presence_dot status={:offline} />
          <span class="text-fg-muted">{dgettext("ui", "离线")}</span>
        <% :disabled -> %>
          <.badge>{dgettext("ui", "已禁用")}</.badge>
        <% :unavailable -> %>
          <.badge tone={:warning}>{dgettext("ui", "不可用")}</.badge>
          <span class="truncate text-caption text-fg-muted" data-unavailable-reason>
            {@runtime.unavailable_reason}
          </span>
      <% end %>
    </span>
    """
  end
end

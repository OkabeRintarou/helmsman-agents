defmodule HelmsmanWeb.Components.TextDiff do
  @moduledoc """
  The line diff of a long text (add-edit-design-conversations D14): the hunks
  of `Helmsman.TaskSpecs.Diff` (or `Helmsman.AgentDesigns.Changes`), added
  lines tinted green, removed ones red, the rest muted; folded by default
  behind 「+N −M 行」.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  attr :id, :string, required: true
  attr :hunks, :list, required: true, doc: "`[%{lines: [{:eq | :del | :ins, text}], ...}]`"
  attr :open, :boolean, default: false

  @doc "The folded diff with its counts."
  def text_diff(assigns) do
    lines = Enum.flat_map(assigns.hunks, & &1.lines)
    assigns = assign(assigns, counts(lines))

    ~H"""
    <details id={@id} open={@open} class="min-w-0" data-diff>
      <summary class="cursor-pointer text-caption text-fg-muted">
        <span class="text-success-fg" data-added={@added}>+{@added}</span>
        <span class="text-danger-fg" data-removed={@removed}>−{@removed}</span>
        {dgettext("ui", "行")}
      </summary>
      <div class="mt-1 overflow-x-auto rounded-field border border-border bg-canvas font-mono text-caption">
        <div :for={{hunk, h} <- Enum.with_index(@hunks)} class="py-1">
          <div :if={h > 0} class="px-2 text-fg-subtle">⋯</div>
          <div
            :for={{op, text} <- hunk.lines}
            class={["whitespace-pre-wrap break-words px-2", line_class(op)]}
            data-op={op}
          >
            {prefix(op)}{text}
          </div>
        </div>
      </div>
    </details>
    """
  end

  @doc "`%{added: n, removed: n}` of the hunks' lines."
  def counts(lines) do
    %{
      added: Enum.count(lines, &match?({:ins, _}, &1)),
      removed: Enum.count(lines, &match?({:del, _}, &1))
    }
  end

  defp line_class(:ins), do: "tint-success text-success-fg"
  defp line_class(:del), do: "tint-danger text-danger-fg"
  defp line_class(:eq), do: "text-fg-muted"

  defp prefix(:ins), do: "+ "
  defp prefix(:del), do: "− "
  defp prefix(:eq), do: "  "
end

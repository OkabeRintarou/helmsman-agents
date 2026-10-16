defmodule Helmsman.AgentDesigns.Kinds do
  @moduledoc """
  The kinds of design conversations (`add-edit-design-conversations`
  decisions 2, 3, 7): the slot each belongs to (one `open` conversation
  per user, workspace and slot, by the partial unique index on the
  generated `slot` column) and its draft tools. A new kind adds one entry
  here; the dispatch points (start, `describe/1`, `view/2`, the prompt,
  `confirm/3`) each get one clause for it.
  """

  @type kind :: :agent | :squad | :agent_edit | :squad_edit
  @type slot :: :create | :edit

  @kinds %{
    agent: %{slot: :create, tools: ~w(get_design propose_agent withdraw_agent), edit?: false},
    squad: %{
      slot: :create,
      tools: ~w(get_design propose_agent withdraw_agent propose_squad),
      edit?: false
    },
    agent_edit: %{slot: :edit, tools: ~w(get_design propose_agent), edit?: true},
    squad_edit: %{
      slot: :edit,
      tools: ~w(get_design propose_agent withdraw_agent propose_squad),
      edit?: true
    }
  }

  @labels %{
    agent: "an agent creation conversation",
    squad: "a squad creation conversation",
    agent_edit: "an agent edit conversation",
    squad_edit: "a squad edit conversation"
  }

  @doc "Every kind, in a stable order."
  @spec kinds() :: [kind()]
  def kinds, do: [:agent, :squad, :agent_edit, :squad_edit]

  @doc "Every slot."
  @spec slots() :: [slot()]
  def slots, do: @kinds |> Map.values() |> Enum.map(& &1.slot) |> Enum.uniq() |> Enum.sort()

  @doc "The slot of `kind` (the generated column's rule)."
  @spec slot(kind()) :: slot()
  def slot(kind), do: Map.fetch!(@kinds, kind).slot

  @doc "The draft tools of a conversation of `kind`."
  @spec tools(kind()) :: [String.t()]
  def tools(kind), do: Map.fetch!(@kinds, kind).tools

  @doc "Every draft tool name, of any kind."
  @spec all_tools() :: [String.t()]
  def all_tools, do: @kinds |> Map.values() |> Enum.flat_map(& &1.tools) |> Enum.uniq()

  @doc "Whether `kind` edits an existing target (it has a target and a baseline)."
  @spec edit?(kind()) :: boolean()
  def edit?(kind), do: Map.fetch!(@kinds, kind).edit?

  @doc "The kind in the English of tool errors, e.g. \"an agent edit conversation\"."
  @spec label(kind()) :: String.t()
  def label(kind), do: Map.fetch!(@labels, kind)

  @doc "The kind `value` names (atom or string), or `:error`."
  @spec parse(term()) :: {:ok, kind()} | :error
  def parse(value) when is_atom(value) and is_map_key(@kinds, value), do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Enum.find(kinds(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      kind -> {:ok, kind}
    end
  end

  def parse(_value), do: :error
end

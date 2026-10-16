defmodule Helmsman.AgentDesigns.Changes do
  @moduledoc """
  The draft of an edit conversation against its baseline
  (`add-edit-design-conversations` decision 10): one change per field that
  differs, `%{field, from, to}`; the long texts (an agent's `instructions`
  and `description`, a squad's `instructions` and `description`) also
  carry `hunks`, the line diff of `Helmsman.TaskSpecs.Diff`; a squad's
  `members` carry `added`, `removed` and `notes` (members whose role note
  changed) instead. `get_design/0`, the prompt and the page share it;
  `text/2` is its English form, the long texts' hunks as unified lines.
  """

  alias Helmsman.AgentDesigns.Draft
  alias Helmsman.TaskSpecs.Diff

  @long ~w(instructions description)
  @squad_fields ~w(description instructions leader members)

  @type change :: %{required(:field) => String.t(), optional(atom()) => term()}

  @doc "The fields of an agent the edit compares (its name is fixed)."
  @spec agent_fields() :: [String.t()]
  def agent_fields, do: Draft.fields() -- ["name"]

  @doc "The fields of a squad the edit compares."
  @spec squad_fields() :: [String.t()]
  def squad_fields, do: @squad_fields

  @doc "The changes of the agent `entry` against `baseline` (`baseline[\"agent\"]`)."
  @spec agent(map(), map() | nil) :: [change()]
  def agent(_baseline, nil), do: []

  def agent(baseline, entry) do
    for field <- agent_fields(),
        (from = Map.get(baseline, field)) != (to = Map.get(entry, field)),
        do: change(field, from, to)
  end

  @doc "The changes of the squad part `squad` against `baseline` (`baseline[\"squad\"]`)."
  @spec squad(map(), map() | nil) :: [change()]
  def squad(_baseline, nil), do: []

  def squad(baseline, squad) do
    for field <- @squad_fields,
        (from = Map.get(baseline, field)) != (to = Map.get(squad, field)),
        do: if(field == "members", do: members(from, to), else: change(field, from, to))
  end

  defp change(field, from, to) when field in @long and is_binary(from) and is_binary(to) do
    %{files: [file]} = Diff.run(%{field => from}, %{field => to})
    %{field: field, from: from, to: to, hunks: file.hunks}
  end

  defp change(field, from, to), do: %{field: field, from: from, to: to}

  defp members(from, to) do
    old = Map.new(List.wrap(from), &{key(&1), &1})
    new = Map.new(List.wrap(to), &{key(&1), &1})

    %{
      field: "members",
      from: from,
      to: to,
      added: for(m <- List.wrap(to), not Map.has_key?(old, key(m)), do: m["name"]),
      removed: for(m <- List.wrap(from), not Map.has_key?(new, key(m)), do: m["name"]),
      notes:
        for(
          m <- List.wrap(to),
          (o = old[key(m)]) && o["role_note"] != m["role_note"],
          do: m["name"]
        )
    }
  end

  defp key(%{"name" => name}) when is_binary(name), do: String.downcase(name)
  defp key(_member), do: nil

  @doc """
  The changes as English lines: `field: from → to`, a long text as its
  unified line diff (`+` / `-` / two spaces), members as added / removed /
  role notes changed. At most `max_bytes` of long-text diff in all; past
  it the rest says to read the full diff with get_design.
  """
  @spec text([change()], pos_integer()) :: String.t()
  def text([], _max_bytes), do: "(no changes)"

  def text(changes, max_bytes) do
    {lines, _left} = Enum.map_reduce(changes, max_bytes, &line/2)
    Enum.join(lines, "\n")
  end

  defp line(%{field: field, hunks: hunks}, left) do
    diff = unified(hunks)

    if byte_size(diff) <= left,
      do: {"#{field}:\n#{diff}", left - byte_size(diff)},
      else: {"#{field}: changed (diff too long here; read it with get_design)", 0}
  end

  defp line(%{field: "members"} = c, left) do
    parts =
      [
        c.added != [] && "added #{Enum.join(c.added, ", ")}",
        c.removed != [] && "removed #{Enum.join(c.removed, ", ")}",
        c.notes != [] && "role note changed for #{Enum.join(c.notes, ", ")}"
      ]
      |> Enum.filter(& &1)

    {"members: #{Enum.join(parts, "; ")}", left}
  end

  defp line(%{field: field, from: from, to: to}, left),
    do: {"#{field}: #{show(from)} → #{show(to)}", left}

  defp show(nil), do: "(none)"
  defp show(""), do: "(empty)"
  defp show(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &show/1) <> "]"
  defp show(%{"name" => name, "host" => host}), do: "#{name} (#{host})"
  defp show(value) when is_binary(value), do: value
  defp show(value), do: inspect(value)

  @doc "The hunks of a long-text change as unified lines."
  @spec unified([Diff.hunk()]) :: String.t()
  def unified(hunks) do
    Enum.map_join(hunks, "\n", fn hunk ->
      header = "@@ -#{hunk.old_start},#{hunk.old_lines} +#{hunk.new_start},#{hunk.new_lines} @@"

      body =
        Enum.map_join(hunk.lines, "\n", fn
          {:eq, text} -> "  " <> text
          {:del, text} -> "- " <> text
          {:ins, text} -> "+ " <> text
        end)

      header <> "\n" <> body
    end)
  end

  @doc "The changes in a JSON-safe form: hunks as unified text (`diff`)."
  @spec json([change()]) :: [map()]
  def json(changes) do
    Enum.map(changes, fn
      %{hunks: hunks} = c -> c |> Map.delete(:hunks) |> Map.put(:diff, unified(hunks))
      c -> c
    end)
  end
end

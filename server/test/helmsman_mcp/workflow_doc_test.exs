defmodule HelmsmanMCP.WorkflowDocTest do
  use ExUnit.Case, async: true

  alias Helmsman.Tasks.{StateMachine, Task}
  alias HelmsmanMCP.Tools

  @docs Path.expand("../../../docs", __DIR__)

  defp doc(name), do: File.read!(Path.join(@docs, name))

  # The rows `| `FROM` | `TO`, `TO` | ... |` of the transition table.
  defp transitions(text) do
    for [_, from, to] <- Regex.scan(~r/^\| `([A-Z_]+)` \| ((?:`[A-Z_]+`(?:, )?)+) \|/m, text),
        into: %{} do
      {status(from), to |> String.split(", ") |> Enum.map(&(&1 |> String.trim("`") |> status()))}
    end
  end

  defp status(name), do: name |> String.downcase() |> String.to_existing_atom()

  # Names called in inline code (`name(...)`), fenced blocks left out.
  defp called_names(text) do
    text = Regex.replace(~r/^```.*?^```/ms, text, "")

    for [_, code] <- Regex.scan(~r/`([^`]+)`/s, text),
        [_, name] <- Regex.scan(~r/\b([a-z_]+)\(/, code),
        uniq: true,
        do: name
  end

  defp sections(text), do: Regex.scan(~r/^## (\d+)\. /m, text) |> Enum.map(&Enum.at(&1, 1))

  for name <- ["AGENT-WORKFLOW.en.md", "AGENT-WORKFLOW.md"] do
    test "#{name}: the transition table is the state machine's" do
      table = transitions(doc(unquote(name)))

      assert Map.keys(table) |> Enum.sort() == Enum.sort(Task.statuses())

      for status <- Task.statuses(),
          do:
            assert(
              Enum.sort(table[status]) == Enum.sort(StateMachine.allowed(status)),
              inspect(status)
            )
    end

    test "#{name}: every tool called exists" do
      names = called_names(doc(unquote(name)))
      tools = Enum.map(Tools.all(), & &1.name())

      assert "transition_task" in names
      assert names -- tools == []
    end
  end

  test "both versions have the same sections and transitions" do
    en = doc("AGENT-WORKFLOW.en.md")
    zh = doc("AGENT-WORKFLOW.md")

    assert sections(en) == Enum.map(1..9, &to_string/1)
    assert sections(zh) == sections(en)
    assert transitions(zh) == transitions(en)
  end
end

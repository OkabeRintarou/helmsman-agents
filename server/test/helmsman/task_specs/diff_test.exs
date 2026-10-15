defmodule Helmsman.TaskSpecs.DiffTest do
  # add-spec-workflow 1.6: the line diff (decision 17).
  use ExUnit.Case, async: true

  alias Helmsman.TaskSpecs.Diff

  test "added, removed, modified and unchanged files, sorted by path" do
    old = %{"a.md" => "same\n", "b.md" => "gone\n", "c.md" => "1\n2\n"}
    new = %{"a.md" => "same\n", "c.md" => "1\nx\n", "d.md" => "new\n"}

    assert %{files: files, truncated: false} = Diff.run(old, new)

    assert Enum.map(files, &{&1.path, &1.change}) == [
             {"a.md", :unchanged},
             {"b.md", :removed},
             {"c.md", :modified},
             {"d.md", :added}
           ]

    assert [%{lines: [{:del, "gone"}], old_start: 1, old_lines: 1, new_lines: 0}] =
             Enum.at(files, 1).hunks

    assert [%{lines: [{:ins, "new"}], new_start: 1, new_lines: 1, old_lines: 0}] =
             Enum.at(files, 3).hunks
  end

  test "three lines of context; distant changes make two hunks" do
    old = Enum.map_join(1..20, "\n", &"line #{&1}")

    new =
      old
      |> String.replace("line 2\n", "line two\n")
      |> String.replace("line 18\n", "line eighteen\n")

    assert %{files: [%{change: :modified, hunks: [first, second]}]} =
             Diff.run(%{"p.md" => old}, %{"p.md" => new})

    assert first.old_start == 1
    assert first.old_lines == 5
    assert first.lines |> Enum.filter(&(elem(&1, 0) == :eq)) |> length() == 4
    assert {:del, "line 2"} in first.lines and {:ins, "line two"} in first.lines

    # Lines 15–20: the file ends two lines after the change.
    assert second.old_start == 15
    assert second.old_lines == 6
    assert second.new_lines == 6
  end

  test "a change of line 3 of proposal.md is one - and one +" do
    old = "## Why\n\nOld reason.\n\n## What Changes\n"
    new = "## Why\n\nNew reason.\n\n## What Changes\n"

    assert %{files: [%{hunks: [hunk]}]} =
             Diff.run(%{"proposal.md" => old}, %{"proposal.md" => new})

    assert Enum.count(hunk.lines, &(elem(&1, 0) == :del)) == 1
    assert Enum.count(hunk.lines, &(elem(&1, 0) == :ins)) == 1
    assert {hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines} == {1, 5, 1, 5}
  end

  test "a file past the time limit is replaced" do
    Process.put(:helmsman_test_hook, fn
      {:spec_diff, "slow.md"} -> Process.sleep(2_500)
      _other -> :ok
    end)

    assert %{
             files: [%{path: "slow.md", change: :replaced, hunks: [], old_lines: 2, new_lines: 3}]
           } =
             Diff.run(%{"slow.md" => "a\nb\n"}, %{"slow.md" => "a\nc\nd\n"})
  end

  test "past 512 KB the remaining hunks are dropped" do
    big = fn tag ->
      Enum.map_join(1..200, "\n", &"#{tag} #{&1} #{String.duplicate("x", 1000)}")
    end

    old = %{"a.md" => big.("a"), "b.md" => big.("b"), "c.md" => big.("c")}
    new = Map.new(old, fn {path, content} -> {path, String.replace(content, "x", "y")} end)

    assert %{truncated: true, files: files} = Diff.run(old, new)
    assert Enum.all?(files, &(&1.change == :modified))
    assert Enum.any?(files, &(&1.hunks != []))
    assert List.last(files).hunks == []
  end
end

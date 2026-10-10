defmodule Helmsman.Tasks.TaskTest do
  use ExUnit.Case, async: true

  alias Helmsman.Tasks.Task

  defp changeset(attrs, task \\ %Task{}), do: Task.changeset(task, attrs)

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  test "defaults: status new, priority medium, no labels" do
    task = changeset(%{title: "Do it"}) |> Ecto.Changeset.apply_changes()
    assert %Task{status: :new, priority: :medium, labels: [], lock_version: 1} = task
  end

  test "trims the title and requires 1-200 characters" do
    assert Ecto.Changeset.get_change(changeset(%{title: "  Do it "}), :title) == "Do it"
    assert errors(changeset(%{title: "  "}))[:title]
    assert errors(changeset(%{title: String.duplicate("t", 201)}))[:title]
    assert changeset(%{title: String.duplicate("题", 200)}).valid?
  end

  test "limits the description to 64 KB" do
    assert errors(changeset(%{title: "T", description: String.duplicate("x", 65_537)}))[
             :description
           ]
  end

  test "accepts the three priorities only" do
    for priority <- ["low", "medium", "high", :high] do
      assert changeset(%{title: "T", priority: priority}).valid?
    end

    assert errors(changeset(%{title: "T", priority: "urgent"}))[:priority]
  end

  test "normalizes labels, keeping their order" do
    changeset = changeset(%{title: "T", labels: [" Backend", "backend", "API ", "  "]})
    assert Ecto.Changeset.get_change(changeset, :labels) == ["backend", "api"]
  end

  test "allows 20 labels of up to 32 characters" do
    labels = for i <- 1..20, do: "l#{i}"
    assert changeset(%{title: "T", labels: labels}).valid?
    assert errors(changeset(%{title: "T", labels: ["l21" | labels]}))[:labels]
    assert errors(changeset(%{title: "T", labels: [String.duplicate("a", 33)]}))[:labels]
    assert changeset(%{title: "T", labels: [String.duplicate("a", 32)]}).valid?
  end

  test "ignores status and every other column" do
    changeset =
      changeset(%{
        title: "T",
        status: "done",
        ident: "X-1",
        seq: 9,
        lock_version: 7,
        project_id: 3
      })

    assert Map.keys(changeset.changes) == [:title]
  end

  test "resubmitting the current values is no change" do
    task = %Task{title: "Same", labels: ["api"], priority: :high, description: ""}

    assert changeset(%{title: " Same ", labels: ["API"], priority: "high"}, task).changes ==
             %{}
  end
end

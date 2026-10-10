defmodule Helmsman.Projects.ProjectTest do
  use ExUnit.Case, async: true

  alias Helmsman.Projects.Project

  defp create(attrs), do: Project.create_changeset(%Project{workspace_id: 1}, attrs)

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  test "upcases the key and trims the name" do
    changeset = create(%{"key" => "bos", "name" => "  Bosun  "})
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :key) == "BOS"
    assert Ecto.Changeset.get_change(changeset, :name) == "Bosun"
  end

  test "rejects invalid keys" do
    for key <- ["1BOS", "B", "BOS-X", "ABCDEFGHIJK", "", "BOS\n"] do
      changeset = create(%{key: key, name: "X"})
      refute changeset.valid?, "key #{inspect(key)}"
      assert errors(changeset)[:key]
    end

    assert create(%{key: "abcdefghij", name: "X"}).valid?
  end

  test "requires a name of 1-80 characters after trimming" do
    assert errors(create(%{key: "BOS", name: "   "}))[:name]
    assert errors(create(%{key: "BOS", name: String.duplicate("名", 81)}))[:name]
    assert create(%{key: "BOS", name: String.duplicate("名", 80)}).valid?
  end

  test "limits the description to 64 KB" do
    assert errors(create(%{key: "BOS", name: "X", description: String.duplicate("é", 32_769)}))[
             :description
           ]

    assert create(%{key: "BOS", name: "X", description: String.duplicate("x", 65_536)}).valid?
  end

  test "the update changeset ignores the key" do
    changeset =
      Project.update_changeset(%Project{key: "BOS", name: "Bosun"}, %{key: "NEW", name: "B"})

    assert changeset.valid?
    assert changeset.changes == %{name: "B"}
  end
end

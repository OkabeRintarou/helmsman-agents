defmodule Helmsman.Backup.Import.ValidateTest do
  use ExUnit.Case, async: true
  alias Helmsman.Backup.Import.Validate
  @at "2026-01-01T00:00:00.000000Z"
  defp snapshot do
    %{
      "format" => "helmsman-export",
      "version" => 1,
      "exported_at" => @at,
      "source" => %{},
      "workspace" => %{},
      "actors" => [%{"name" => "alice", "kind" => "human", "disabled" => false, "owner" => nil}],
      "projects" => [
        %{
          "key" => "BOS",
          "name" => "Project",
          "description" => "",
          "task_seq" => 2,
          "archived_at" => nil,
          "created_at" => @at,
          "updated_at" => @at
        }
      ],
      "tasks" =>
        Enum.map(1..2, fn n ->
          %{
            "id" => "BOS-#{n}",
            "project" => "BOS",
            "seq" => n,
            "title" => "Task",
            "description" => "",
            "status" => "new",
            "priority" => "medium",
            "kind" => "task",
            "labels" => [],
            "epic" => nil,
            "created_by" => "alice",
            "assignee" => nil,
            "created_at" => @at,
            "updated_at" => @at
          }
        end),
      "task_events" => [],
      "feedback" => [],
      "links" => [],
      "saved_filters" => []
    }
  end

  test "valid empty histories and unsupported version" do
    assert {:ok, _} = Validate.validate(snapshot())
    assert {:error, :unsupported_format} = Validate.validate(Map.put(snapshot(), "version", 2))
  end

  test "field type, value, size, identity, key and uniqueness rules" do
    for {collection, field, value} <- [
          {"actors", "name", "Alice"},
          {"actors", "kind", "bot"},
          {"actors", "disabled", "no"},
          {"projects", "key", "B"},
          {"projects", "name", ""},
          {"projects", "description", String.duplicate("x", 65_537)},
          {"projects", "task_seq", 0},
          {"tasks", "id", "BOS-3"},
          {"tasks", "seq", 0},
          {"tasks", "title", ""},
          {"tasks", "title", String.duplicate("x", 201)},
          {"tasks", "title", String.duplicate("a\u0301", 101)},
          {"tasks", "description", String.duplicate("x", 65_537)},
          {"tasks", "status", "closed"},
          {"tasks", "priority", "mega"},
          {"tasks", "kind", "issue"},
          {"tasks", "labels", List.duplicate("x", 21)},
          {"tasks", "labels", [String.duplicate("x", 33)]},
          {"tasks", "created_at", "tomorrow"},
          {"tasks", "epic", "BOS-2"},
          {"tasks", "created_by", "missing"},
          {"tasks", "assignee", "missing"}
        ] do
      input =
        Map.update!(snapshot(), collection, fn rows ->
          List.update_at(rows, 0, &Map.put(&1, field, value))
        end)

      assert {:error, {:invalid_import, [_ | _]}} = Validate.validate(input),
             "#{collection}.#{field}"
    end

    for collection <- ~w(actors projects tasks) do
      input = Map.update!(snapshot(), collection, fn rows -> rows ++ [hd(rows)] end)
      assert {:error, {:invalid_import, errors}} = Validate.validate(input)
      assert Enum.any?(errors, &(&1.message == "duplicate record"))
    end
  end

  test "feedback reciprocal links, root thread and state must agree" do
    row = %{
      "id" => "BOS-1#1",
      "thread" => 1,
      "author" => "alice",
      "kind" => "comment",
      "content" => "hi",
      "status" => "active",
      "supersedes" => nil,
      "superseded_by" => nil,
      "mentions" => [],
      "fallback" => false,
      "at" => @at
    }

    for {field, value} <- [
          {"thread", 2},
          {"supersedes", "BOS-2#1"},
          {"superseded_by", "BOS-1#2"},
          {"status", "superseded"},
          {"mentions", ["missing"]},
          {"content", ""},
          {"id", "BOS-1#2147483648"},
          {"kind", "invalid"}
        ] do
      assert {:error, {:invalid_import, [_ | _]}} =
               Validate.validate(Map.put(snapshot(), "feedback", [Map.put(row, field, value)]))
    end
  end

  test "event continuity, last state and references" do
    row = %{
      "task" => "BOS-1",
      "n" => 1,
      "from" => nil,
      "to" => "new",
      "actor" => "alice",
      "comment" => nil,
      "commits" => [],
      "tests" => nil,
      "auto" => false,
      "auto_reason" => nil,
      "feedback" => nil,
      "verified_sha" => nil,
      "assignee_side" => [],
      "at" => @at
    }

    for {field, value} <- [
          {"n", 2},
          {"to", "done"},
          {"task", "BOS-99"},
          {"actor", "missing"},
          {"feedback", "BOS-1#1"},
          {"assignee_side", ["missing"]},
          {"comment", String.duplicate("a", 10_001)},
          {"commits", ["not-sha"]},
          {"tests", %{}},
          {"auto_reason", "unknown"}
        ] do
      assert {:error, {:invalid_import, [_ | _]}} =
               Validate.validate(Map.put(snapshot(), "task_events", [Map.put(row, field, value)]))
    end
  end

  test "links are resolvable, non-self and acyclic; rename is validated" do
    link = %{
      "from" => "BOS-1",
      "to" => "BOS-2",
      "type" => "depends_on",
      "actor" => "alice",
      "at" => @at
    }

    assert {:error, {:invalid_import, [_ | _]}} =
             Validate.validate(
               Map.put(snapshot(), "links", [
                 link,
                 Map.merge(link, %{"from" => "BOS-2", "to" => "BOS-1"})
               ])
             )

    for invalid <- [
          Map.put(link, "to", "BOS-99"),
          Map.put(link, "to", "BOS-1"),
          Map.put(link, "type", "relates")
        ] do
      assert {:error, {:invalid_import, [_ | _]}} =
               Validate.validate(Map.put(snapshot(), "links", [invalid]))
    end

    for rename <- [%{"missing" => "bob"}, %{"alice" => "Bob"}, %{"alice" => "helmsman"}, []] do
      assert {:error, {:invalid_import, [_ | _]}} = Validate.validate(snapshot(), rename)
    end
  end

  test "errors cap at one hundred and carry paths" do
    data = Map.put(snapshot(), "tasks", List.duplicate(%{}, 150))
    assert {:error, {:invalid_import, errors}} = Validate.validate(data)
    assert length(errors) == 100
    assert Enum.all?(errors, &is_binary(&1.path))
  end
end

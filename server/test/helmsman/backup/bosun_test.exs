defmodule Helmsman.Backup.BosunTest do
  use ExUnit.Case, async: true
  alias Helmsman.Backup.Bosun
  alias Helmsman.Backup.Import.Validate
  defp fixture, do: File.read!("test/fixtures/bosun/export-v2.json") |> Jason.decode!()

  test "synthetic v2 fixture converts archived projects, Epic, revisions, links, filters and user" do
    assert {:ok, data} = Bosun.convert(fixture(), "alice")
    assert {:ok, ^data} = Validate.validate(data)
    assert hd(data["projects"])["archived_at"] == data["exported_at"]
    assert Enum.at(data["tasks"], 1)["epic"] == "BOS-1"
    assert Enum.at(data["feedback"], 1)["thread"] == 1
    assert hd(data["feedback"])["status"] == "superseded"
    assert hd(data["tasks"])["created_by"] == "alice"
    assert hd(data["saved_filters"])["owner"] == "alice"
    refute Enum.any?(data["actors"], &(&1["name"] == "user"))
    assert {:ok, renamed} = Bosun.convert(fixture(), "alice", %{"user" => "bob"})
    assert hd(renamed["tasks"])["created_by"] == "bob"
  end

  test "reverse chronological history becomes increasing events" do
    input = fixture()
    task = hd(input["tasks"])
    h = hd(task["history"])

    task =
      Map.merge(task, %{
        "status" => "DONE",
        "history" => [
          Map.merge(h, %{"from" => "IN_PROGRESS", "to" => "DONE", "at" => 1_735_689_600_002}),
          Map.merge(h, %{"from" => "NEW", "to" => "IN_PROGRESS", "at" => 1_735_689_600_001}),
          h
        ]
      })

    input = Map.update!(input, "tasks", fn [_ | rest] -> [task | rest] end)
    assert {:ok, data} = Bosun.convert(input, "alice")

    assert data["task_events"] |> Enum.filter(&(&1["task"] == task["id"])) |> Enum.map(& &1["to"]) ==
             ~w(new in_progress done)
  end

  test "validation paths reference bosun history and filter fields" do
    input =
      Map.update!(fixture(), "tasks", fn tasks ->
        List.update_at(tasks, 0, fn t ->
          Map.update!(t, "history", fn [h] -> [Map.put(h, "actor", "bad name")] end)
        end)
      end)

    assert {:error, {:invalid_import, errors}} = Bosun.convert(input, "alice")
    assert Enum.any?(errors, &(&1.path == "tasks[0].history[0].actor"))
    assert {:error, :unsupported_format} = Bosun.convert(%{}, "alice")
  end
end

defmodule Helmsman.Backup.Import.MergeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Helmsman.Backup.Import.Merge
  @task %{"kind" => "task", "updated_at" => "2026-01-01T00:00:00.000000Z"}
  property "compatible audit sequences classify every prefix length pair" do
    check all events <-
                list_of(
                  fixed_map(%{
                    "to" => member_of(["new", "todo", "in_progress", "done"]),
                    "actor" => string(:alphanumeric, min_length: 1, max_length: 10),
                    "comment" => string(:printable, max_length: 20)
                  }),
                  max_length: 15
                ),
              feedback <-
                list_of(
                  fixed_map(%{
                    "author" => string(:alphanumeric, min_length: 1, max_length: 10),
                    "kind" => member_of(["note", "question", "answer"]),
                    "content" => string(:printable, max_length: 20)
                  }),
                  max_length: 15
                ),
              le <- integer(0..length(events)),
              ie <- integer(0..length(events)),
              lf <- integer(0..length(feedback)),
              inf <- integer(0..length(feedback)) do
      expected =
        cond do
          (le < ie and lf > inf) or (le > ie and lf < inf) -> {:error, :crossed_prefixes}
          le > ie or lf > inf -> :local_newer
          le < ie or lf < inf -> :fast_forwarded
          true -> :unchanged
        end

      local_events = Enum.take(events, le)
      incoming_events = Enum.take(events, ie)
      local_feedback = Enum.take(feedback, lf)
      incoming_feedback = Enum.take(feedback, inf)

      assert Merge.classify(
               @task,
               @task,
               local_events,
               incoming_events,
               local_feedback,
               incoming_feedback
             ) == expected

      if min(le, ie) > 0 do
        fork =
          List.update_at(incoming_events, 0, &Map.put(&1, "comment", "fork:" <> &1["comment"]))

        assert {:error, {:event, 1}} =
                 Merge.classify(
                   @task,
                   @task,
                   local_events,
                   fork,
                   local_feedback,
                   incoming_feedback
                 )
      end
    end
  end

  test "reply relation changes fork the audit prefix and missing legacy fields are nil" do
    reply = %{"reply_to" => "BOS-1#1", "reply_root" => "BOS-1#1"}

    assert {:error, {:feedback, 1}} =
             Merge.classify(@task, @task, [], [], [reply], [Map.put(reply, "reply_to", "BOS-1#2")])

    assert :unchanged =
             Merge.classify(@task, @task, [], [], [%{}], [
               %{"reply_to" => nil, "reply_root" => nil}
             ])
  end

  test "same sequence fork is rejected; newer fields and supersession advance" do
    assert {:error, {:event, 1}} =
             Merge.classify(@task, @task, [%{"to" => "new"}], [%{"to" => "done"}], [], [])

    assert :fast_forwarded =
             Merge.classify(
               @task,
               Map.put(@task, "updated_at", "2026-01-02T00:00:00.000000Z"),
               [],
               [],
               [],
               []
             )

    assert :fast_forwarded =
             Merge.classify(@task, @task, [], [], [%{"status" => "active"}], [
               %{"status" => "superseded"}
             ])

    assert :unchanged =
             Merge.classify(@task, @task, [], [], [%{"status" => "superseded"}], [
               %{"status" => "active"}
             ])

    assert {:error, :kind} = Merge.classify(@task, Map.put(@task, "kind", "epic"), [], [], [], [])
  end
end

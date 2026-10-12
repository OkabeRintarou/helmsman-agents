defmodule Helmsman.Tasks.TransitionFeedbackTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Tx

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    alice = workspace_scope_fixture(alice, workspace)
    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    keel = %{alice | actor: agent_fixture(workspace, alice.user, "keel/dev")}

    task = task_fixture(alice, "BOS")
    {:ok, _} = Tasks.transition(keel, task.ident, "in_progress")
    {:ok, _} = Tasks.transition(keel, task.ident, "done")

    %{owner: owner_scope, alice: alice, keel: keel, task: task}
  end

  defp subscribe(task) do
    Events.subscribe(Events.topic(:project, task.project_id))
    Events.subscribe(Events.topic(:task, task.id))
  end

  defp refute_notified do
    refute_receive {:feedback_added, _}
    refute_receive {:task_updated, _}
    refute_receive {:task_transitioned, _}
  end

  # Everything a reason may change.
  defp snapshot(task) do
    row = Repo.get!(Task, task.id)

    {row.status, row.feedback_seq, row.feedback_count, row.open_question,
     Repo.aggregate(where(TaskEvent, task_id: ^task.id), :count),
     Repo.aggregate(where(Entry, task_id: ^task.id), :count)}
  end

  @reason %{kind: :review, content: "缺少测试"}

  describe "a transition with a reason" do
    test "sending back with a review", %{alice: alice, task: task} do
      Feedback.add(alice, task.ident, %{kind: :question, content: "why?"})
      subscribe(task)

      assert {:ok, detail} =
               Tasks.transition(alice, task.ident, "in_progress", feedback: @reason)

      assert %{status: "in_progress", feedback_count: 2, open_question: true} = detail

      assert %{id: "BOS-1#2", kind: "review", content: "缺少测试", author: %{kind: "human"}} =
               List.last(detail.feedback)

      assert %{to: "in_progress", feedback: "BOS-1#2"} = List.last(detail.history)
      assert Enum.all?(Enum.drop(detail.history, -1), &is_nil(&1.feedback))

      assert_receive {:feedback_added, %{id: "BOS-1#2", kind: "review"}}
      assert_receive {:task_updated, %{id: "BOS-1", status: "in_progress", feedback_count: 2}}

      assert_receive {:task_transitioned,
                      %{ident: "BOS-1", event: %{to: "in_progress", feedback: "BOS-1#2"}}}

      refute_receive {:task_updated, _}

      {:ok, reloaded} = Tasks.get(alice, task.ident)
      assert List.last(Tasks.detail(reloaded).history).feedback == "BOS-1#2"
    end

    test "string keys, the default kind and an answer", %{alice: alice, keel: keel, task: task} do
      Feedback.add(keel, task.ident, %{kind: :question, content: "ok?"})

      assert {:ok, %{feedback: [_, reason], open_question: false}} =
               Tasks.transition(alice, task.ident, "in_progress", %{
                 "feedback" => %{"kind" => "answer", "content" => "no"}
               })

      assert reason.kind == "answer"

      assert {:ok, %{feedback: [_, _, %{kind: "comment"}]}} =
               Tasks.transition(alice, task.ident, "done", feedback: %{content: "done now"})
    end

    test "a rejected transition writes nothing", %{alice: alice, task: task} do
      subscribe(task)
      before = snapshot(task)

      assert {:error, {:invalid_transition, :done, :cancelled, _}} =
               Tasks.transition(alice, task.ident, "cancelled", feedback: @reason)

      assert snapshot(task) == before
      refute_notified()
      assert {:ok, %Entry{seq: 1}} = Feedback.add(alice, task.ident, %{content: "x"})
    end

    test "an invalid reason fails before any query", %{alice: alice, task: task} do
      before = snapshot(task)
      handler = "transition-feedback-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:helmsman, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == test_pid, do: send(test_pid, :query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, changeset} =
               Tasks.transition(alice, task.ident, "in_progress", feedback: %{content: "  "})

      assert "can't be blank" in errors_on(changeset).content

      assert Tasks.transition(alice, task.ident, "in_progress", feedback: "text") ==
               {:error, {:invalid_feedback, :not_an_object}}

      refute_received :query
      :telemetry.detach(handler)
      assert snapshot(task) == before
    end

    test "without a reason the entry refers to none", %{alice: alice, task: task} do
      assert {:ok, detail} = Tasks.transition(alice, task.ident, "in_progress", feedback: nil)
      assert List.last(detail.history).feedback == nil
      assert detail.feedback == []
    end
  end

  describe "atomicity (review R2)" do
    test "a failure after the reason is written rolls everything back",
         %{alice: alice, task: task} do
      subscribe(task)
      before = snapshot(task)

      Process.put(:helmsman_test_hook, fn
        :reason_inserted ->
          # The reason and the counters are written inside the transaction.
          assert %{rows: [[1, 1]]} =
                   Repo.query!(
                     "SELECT feedback_seq, feedback_count FROM tasks WHERE id = $1",
                     [task.id]
                   )

          raise "boom"

        _other ->
          :ok
      end)

      assert_raise RuntimeError, "boom", fn ->
        Tasks.transition(alice, task.ident, "in_progress", feedback: @reason)
      end

      Process.delete(:helmsman_test_hook)

      assert snapshot(task) == before
      refute_notified()
      assert {:ok, %Entry{seq: 1}} = Feedback.add(alice, task.ident, %{content: "x"})
    end

    test "an outer transaction that fails rolls a transition with a reason back",
         %{alice: alice, task: task} do
      subscribe(task)
      before = snapshot(task)

      assert Tx.run(fn ->
               {:ok, %{status: "in_progress"}} =
                 Tasks.transition(alice, task.ident, "in_progress", feedback: @reason)

               {:error, :boom}
             end) == {:error, :boom}

      assert snapshot(task) == before
      refute_notified()
      assert {:ok, %Entry{seq: 1}} = Feedback.add(alice, task.ident, %{content: "x"})
    end
  end
end

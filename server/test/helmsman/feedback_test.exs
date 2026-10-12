defmodule Helmsman.FeedbackTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    [alice, bob, viewer] =
      for role <- [:member, :member, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        workspace_scope_fixture(user, workspace)
      end

    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    keel = %{bob | actor: agent_fixture(workspace, bob.user, "keel/dev")}
    alice_dev = %{alice | actor: agent_fixture(workspace, alice.user, "alice/dev")}
    task = task_fixture(alice, "BOS")

    %{
      workspace: workspace,
      owner: owner_scope,
      alice: alice,
      alice_dev: alice_dev,
      bob: bob,
      keel: keel,
      viewer: viewer,
      task: task
    }
  end

  defp add!(scope, task, kind, content \\ "Text") do
    assert {:ok, entry} = Feedback.add(scope, task.ident, %{kind: kind, content: content})
    entry
  end

  defp id(entry), do: Feedback.view(entry).id

  defp reload(scope, task) do
    {:ok, task} = Tasks.get(scope, task.ident)
    task
  end

  defp subscribe(task) do
    Events.subscribe(Events.topic(:project, task.project_id))
    Events.subscribe(Events.topic(:task, task.id))
  end

  describe "add/3" do
    test "gives the next number and counts the record", %{alice: alice, task: task} do
      add!(alice, task, :comment)
      add!(alice, task, :comment)

      assert {:ok, entry} = Feedback.add(alice, "bos-1", %{content: "Third"})

      assert %{id: "BOS-1#3", seq: 3, thread_seq: 3, kind: "comment", status: "active"} =
               Feedback.view(entry)

      assert Feedback.view(entry).author == %{name: alice.actor.name, kind: "human"}

      task = reload(alice, task)
      assert {task.feedback_seq, task.feedback_count, task.open_question} == {3, 3, false}
    end

    test "string keys and every kind", %{alice: alice, task: task} do
      for kind <- ["comment", "review", "question", "answer"] do
        assert {:ok, %Entry{kind: atom}} =
                 Feedback.add(alice, task.ident, %{"kind" => kind, "content" => "x"})

        assert Atom.to_string(atom) == kind
      end
    end

    test "content is kept as written", %{alice: alice, task: task} do
      entry = add!(alice, task, :comment, "    code block\n\ntext\n")
      assert entry.content == "    code block\n\ntext\n"
    end

    test "blank content takes no number", %{alice: alice, task: task} do
      subscribe(task)

      for content <- ["", "   \n\t ", nil] do
        assert {:error, changeset} = Feedback.add(alice, task.ident, %{content: content})
        assert "can't be blank" in errors_on(changeset).content
      end

      assert {:error, changeset} = Feedback.add(alice, task.ident, %{kind: :comment})
      assert "can't be blank" in errors_on(changeset).content

      assert {:error, changeset} =
               Feedback.add(alice, task.ident, %{content: String.duplicate("a", 65_537)})

      assert %{content: [_]} = errors_on(changeset)

      assert {:error, changeset} = Feedback.add(alice, task.ident, %{kind: :note, content: "x"})
      assert "is invalid" in errors_on(changeset).kind

      assert reload(alice, task).feedback_seq == 0
      refute_receive {:feedback_added, _}
      refute_receive {:task_updated, _}

      assert add!(alice, task, :comment).seq == 1
    end

    test "64 KB is the limit", %{alice: alice, task: task} do
      assert add!(alice, task, :comment, String.duplicate("a", 65_536)).seq == 1
    end

    test "viewers may not add", %{viewer: viewer, alice: alice, task: task} do
      assert Feedback.add(viewer, task.ident, %{content: "x"}) == {:error, :forbidden}
      assert reload(alice, task).feedback_seq == 0
    end

    test "agents of members may add", %{keel: keel, task: task} do
      assert %{author: %{name: "keel/dev", kind: "agent"}} =
               Feedback.view(add!(keel, task, :question))
    end

    test "unknown tasks, other workspaces and no actor", %{alice: alice, task: task} do
      assert Feedback.add(alice, "BOS-99", %{content: "x"}) == {:error, :not_found}
      assert Feedback.add(alice, "nope", %{content: "x"}) == {:error, :not_found}

      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      project_fixture(other_scope, key: "BOS")
      assert Feedback.add(other_scope, task.ident, %{content: "x"}) == {:error, :not_found}

      assert Feedback.add(%{alice | actor: nil}, task.ident, %{content: "x"}) ==
               {:error, :no_actor}
    end

    test "does not touch the task version", %{alice: alice, task: task} do
      add!(alice, task, :question)
      assert reload(alice, task).lock_version == task.lock_version
      assert {:ok, _} = Tasks.update(alice, task.ident, %{title: "New"}, task.lock_version)
    end

    test "stores the mentions", %{alice: alice, keel: keel, task: task} do
      entry = add!(alice, task, :comment, "@keel/dev look, and `@alice` in code")
      assert entry.mentions == [keel.actor.id]
      assert Feedback.view(entry).mentions == ["keel/dev"]
    end
  end

  describe "revise/3" do
    test "the author revises: new number, old place", %{keel: keel, alice: alice, task: task} do
      for _ <- 1..2, do: add!(alice, task, :comment)
      third = add!(keel, task, :question, "first try")
      add!(alice, task, :comment)

      assert {:ok, revised} = Feedback.revise(keel, "bos-1#3", %{content: "second try"})

      assert %{
               id: "BOS-1#5",
               seq: 5,
               thread_seq: 3,
               kind: "question",
               content: "second try",
               supersedes: "BOS-1#3",
               superseded_by: nil,
               status: "active",
               author: %{name: "keel/dev"}
             } = Feedback.view(revised)

      assert {:ok, old} = Feedback.get(alice, id(third))

      assert %{status: "superseded", superseded_by: "BOS-1#5", content: "first try"} =
               Feedback.view(old)

      # The timeline order: by place.
      {:ok, entries} = Feedback.list(alice, task.ident)
      active = entries |> Enum.filter(&(&1.status == :active)) |> Enum.sort_by(& &1.thread_seq)
      assert Enum.map(active, & &1.seq) == [1, 2, 5, 4]
    end

    test "a user revises their agent's record", %{alice: alice, alice_dev: alice_dev, task: task} do
      entry = add!(alice_dev, task, :comment)

      assert {:ok, revised} = Feedback.revise(alice, id(entry), %{content: "fixed"})
      assert Feedback.view(revised).author == %{name: alice.actor.name, kind: "human"}
    end

    test "an agent revises its user's record", %{alice: alice, alice_dev: alice_dev, task: task} do
      entry = add!(alice, task, :comment)

      assert {:ok, revised} = Feedback.revise(alice_dev, id(entry), %{content: "fixed"})
      assert Feedback.view(revised).author == %{name: "alice/dev", kind: "agent"}
    end

    test "someone else's record is forbidden", ctx do
      entry = add!(ctx.alice, ctx.task, :comment)
      subscribe(ctx.task)

      assert Feedback.revise(ctx.bob, id(entry), %{content: "x"}) == {:error, :forbidden}
      assert Feedback.revise(ctx.keel, id(entry), %{content: "x"}) == {:error, :forbidden}
      assert Feedback.revise(ctx.owner, id(entry), %{content: "x"}) == {:error, :forbidden}
      assert Feedback.revise(ctx.viewer, id(entry), %{content: "x"}) == {:error, :forbidden}

      assert reload(ctx.alice, ctx.task).feedback_seq == 1
      refute_receive {:feedback_added, _}
    end

    test "viewers may not revise even their own record", ctx do
      entry = add!(ctx.alice, ctx.task, :comment)

      Helmsman.Repo.update_all(
        from(m in Helmsman.Workspaces.Membership,
          where: m.user_id == ^ctx.alice.user.id and m.workspace_id == ^ctx.workspace.id
        ),
        set: [role: :viewer]
      )

      assert Feedback.revise(ctx.alice, id(entry), %{content: "x"}) == {:error, :forbidden}
    end

    test "a superseded record points to the latest", %{keel: keel, task: task} do
      first = add!(keel, task, :comment, "v1")
      {:ok, _second} = Feedback.revise(keel, id(first), %{content: "v2"})
      {:ok, third} = Feedback.revise(keel, "BOS-1#2", %{content: "v3"})
      assert id(third) == "BOS-1#3"

      assert Feedback.revise(keel, "BOS-1#1", %{content: "v4"}) ==
               {:error, {:superseded, "BOS-1#3"}}

      assert Feedback.revise(keel, "BOS-1#2", %{content: "v4"}) ==
               {:error, {:superseded, "BOS-1#3"}}
    end

    test "the system's records are never revised", ctx do
      {:ok, system} = Actors.ensure_system(ctx.workspace)
      insert_entry!(ctx.task, system, 1)

      assert Feedback.revise(ctx.owner, "BOS-1#1", %{content: "x"}) == {:error, :forbidden}
    end

    test "the kind may change, and stays otherwise", %{alice: alice, task: task} do
      entry = add!(alice, task, :question)

      assert {:ok, %Entry{kind: :question} = second} =
               Feedback.revise(alice, id(entry), %{content: "y"})

      assert {:ok, %Entry{kind: :comment}} =
               Feedback.revise(alice, id(second), %{"kind" => "comment", "content" => "z"})
    end

    test "invalid input, unknown and malformed IDs", %{alice: alice, task: task} do
      entry = add!(alice, task, :comment)
      assert {:error, %Ecto.Changeset{}} = Feedback.revise(alice, id(entry), %{content: " "})
      assert Feedback.revise(alice, "BOS-1#9", %{content: "x"}) == {:error, :not_found}
      assert Feedback.revise(alice, "BOS-1#01", %{content: "x"}) == {:error, :not_found}
      assert Feedback.revise(alice, "BOS-9#1", %{content: "x"}) == {:error, :not_found}

      assert Feedback.revise(%{alice | actor: nil}, id(entry), %{content: "x"}) ==
               {:error, :no_actor}
    end

    test "revising re-reads the mentions", %{alice: alice, keel: keel, task: task} do
      entry = add!(alice, task, :comment, "no one")
      {:ok, revised} = Feedback.revise(alice, id(entry), %{content: "cc @keel/dev"})
      assert revised.mentions == [keel.actor.id]
    end
  end

  describe "the active count" do
    test "a revision keeps it", %{alice: alice, task: task} do
      for _ <- 1..3, do: add!(alice, task, :comment)
      {:ok, _} = Feedback.revise(alice, "BOS-1#2", %{content: "again"})

      task = reload(alice, task)
      assert {task.feedback_count, task.feedback_seq} == {3, 4}
      assert {:ok, entries} = Feedback.list(alice, task.ident)
      assert length(entries) == 4
      assert Tasks.summary(task).feedback_count == 3
    end
  end

  describe "the open question" do
    defp open?(scope, task), do: reload(scope, task).open_question

    test "comments and reviews leave it open", %{alice: alice, keel: keel, task: task} do
      add!(keel, task, :question)
      assert open?(alice, task)
      add!(alice, task, :comment)
      add!(alice, task, :review)
      assert open?(alice, task)
    end

    test "an answer closes it, a new question opens it", %{alice: alice, keel: keel, task: task} do
      refute open?(alice, task)
      add!(keel, task, :question)
      add!(alice, task, :answer)
      refute open?(alice, task)
      add!(keel, task, :question)
      assert open?(alice, task)
    end

    test "revising an answered question keeps its place", %{alice: alice, keel: keel, task: task} do
      add!(alice, task, :comment)
      question = add!(keel, task, :question)
      add!(alice, task, :answer)

      assert {:ok, revised} = Feedback.revise(keel, id(question), %{content: "rephrased"})
      assert {revised.seq, revised.thread_seq} == {4, 2}
      refute open?(alice, task)
    end

    test "an answer revised into a comment reopens it", %{alice: alice, keel: keel, task: task} do
      add!(keel, task, :question)
      answer = add!(alice, task, :answer)
      refute open?(alice, task)

      {:ok, _} = Feedback.revise(alice, id(answer), %{kind: :comment, content: "not an answer"})
      assert open?(alice, task)
    end

    test "a question revised into a comment closes it", %{keel: keel, alice: alice, task: task} do
      question = add!(keel, task, :question)
      {:ok, _} = Feedback.revise(keel, id(question), %{kind: "comment", content: "never mind"})
      refute open?(alice, task)
    end
  end

  describe "reading" do
    test "list/2: every record by number", %{alice: alice, viewer: viewer, task: task} do
      a = add!(alice, task, :comment)
      add!(alice, task, :question)
      {:ok, _} = Feedback.revise(alice, id(a), %{content: "v2"})

      assert {:ok, entries} = Feedback.list(viewer, "bos-1")

      assert Enum.map(entries, &{Feedback.view(&1).id, Feedback.view(&1).status}) == [
               {"BOS-1#1", "superseded"},
               {"BOS-1#2", "active"},
               {"BOS-1#3", "active"}
             ]

      assert Feedback.list(viewer, "BOS-9") == {:error, :not_found}
      assert Feedback.list(viewer, "x") == {:error, :not_found}
    end

    test "get/2 in any case; other workspaces are not found", %{alice: alice, task: task} do
      add!(alice, task, :comment)
      assert {:ok, entry} = Feedback.get(alice, "bos-1#1")
      assert id(entry) == "BOS-1#1"
      assert Feedback.get(alice, "BOS-1#2") == {:error, :not_found}

      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      assert Feedback.get(other_scope, "BOS-1#1") == {:error, :not_found}
    end

    test "the task detail and summary", %{alice: alice, keel: keel, task: task} do
      add!(alice, task, :comment)
      q = add!(keel, task, :question, "@#{alice.actor.name}? see `@keel/dev`")
      {:ok, _} = Feedback.revise(keel, id(q), %{content: "v2"})

      detail = Tasks.detail(reload(alice, task))
      assert %{feedback_count: 2, open_question: true} = detail
      assert Enum.map(detail.feedback, & &1.id) == ["BOS-1#1", "BOS-1#2", "BOS-1#3"]
      assert Enum.at(detail.feedback, 1).mentions == [alice.actor.name]

      {:ok, [summary]} = Tasks.list(alice, "BOS")
      assert %{feedback_count: 2, open_question: true} = Tasks.summary(summary)
    end
  end

  describe "notifications" do
    test "after an addition", %{keel: keel, task: task} do
      subscribe(task)
      add!(keel, task, :question)

      assert_receive {:feedback_added, %{id: "BOS-1#1", kind: "question"}}
      assert_receive {:task_updated, %{id: "BOS-1", open_question: true, feedback_count: 1}}
      refute_receive {:task_updated, _}
    end

    test "after a revision, pointing to the superseded record", %{alice: alice, task: task} do
      entry = add!(alice, task, :comment)
      subscribe(task)
      {:ok, _} = Feedback.revise(alice, id(entry), %{content: "v2"})

      assert_receive {:feedback_added, %{id: "BOS-1#2", supersedes: "BOS-1#1"}}
      assert_receive {:task_updated, %{id: "BOS-1", feedback_count: 1}}
    end

    test "nothing when a write fails or is rolled back", %{alice: alice, bob: bob, task: task} do
      entry = add!(alice, task, :comment)
      subscribe(task)

      assert {:error, :forbidden} = Feedback.revise(bob, id(entry), %{content: "x"})

      assert Helmsman.Tx.run(fn ->
               {:ok, _} = Feedback.add(alice, task.ident, %{content: "x"})
               {:error, :boom}
             end) == {:error, :boom}

      refute_receive {:feedback_added, _}
      refute_receive {:task_updated, _}
      assert add!(alice, task, :comment).seq == 2
    end
  end

  defp insert_entry!(task, actor, seq) do
    Repo.insert_all(Entry, [
      %{
        workspace_id: task.workspace_id,
        task_id: task.id,
        seq: seq,
        thread_seq: seq,
        author_id: actor.id,
        kind: :comment,
        content: "system says",
        inserted_at: DateTime.utc_now()
      }
    ])

    Repo.update_all(where(Tasks.Task, id: ^task.id),
      set: [feedback_seq: seq, feedback_count: seq]
    )
  end
end

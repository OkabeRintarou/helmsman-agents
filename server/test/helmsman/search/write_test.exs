defmodule Helmsman.Search.WriteTest do
  # add-fulltext-search 1.4: the search columns are written in the
  # transaction of every write (decision 5).
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Search, Tasks, Tx}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks.Task

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    %{scope: scope, workspace: workspace}
  end

  defp ids(scope, query) do
    {:ok, hits} = Search.search(scope, query)
    Enum.map(hits, & &1.task.id)
  end

  defp search_column(%Task{id: id}),
    do: Repo.one!(from(t in Task, where: t.id == ^id, select: t.search))

  test "建单后立即可搜", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "修复登录超时")
    assert ids(scope, "登录") == [task.ident]
  end

  test "改标题", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "修复登录超时")
    {:ok, _} = Tasks.update(scope, task.ident, %{title: "重构会话管理"})
    assert ids(scope, "登录") == []
    assert ids(scope, "会话") == [task.ident]
  end

  test "description and labels edits are indexed too", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "x")
    {:ok, _} = Tasks.update(scope, task.ident, %{description: "deadlock in the pool"})
    assert ids(scope, "deadlock") == [task.ident]
    {:ok, _} = Tasks.update(scope, task.ident, %{labels: ["backend"]})
    assert ids(scope, "backend") == [task.ident]
  end

  test "写入失败: a stale edit leaves the search as it was", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "修复登录超时")
    before = search_column(task)
    assert {:error, :stale} = Tasks.update(scope, task.ident, %{title: "重构会话"}, 99)
    assert search_column(task) == before
    assert ids(scope, "登录") == [task.ident]
    assert ids(scope, "会话") == []
  end

  test "an edit that only changes the priority does not touch the column", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "修复登录超时")
    before = search_column(task)
    {:ok, _} = Tasks.update(scope, task.ident, %{priority: "high"})
    # Same value, but also the statement did not write it: rewrite to
    # something else and see an unrelated edit keep it.
    {1, _} = Repo.update_all(where(Task, id: ^task.id), set: [search: []])
    {:ok, _} = Tasks.update(scope, task.ident, %{priority: "low"})
    assert search_column(task) == []
    assert before != []
  end

  test "an error raised inside the transaction rolls the column back", %{scope: scope} do
    task = task_fixture(scope, "BOS", title: "修复登录超时")

    assert_raise RuntimeError, "boom", fn ->
      Tx.run(fn ->
        {:ok, _} = Tasks.update(scope, task.ident, %{title: "重构会话"})
        assert ids(scope, "会话") == [task.ident]
        raise "boom"
      end)
    end

    assert ids(scope, "登录") == [task.ident]
    assert ids(scope, "会话") == []
  end

  describe "overlong terms (code-review-1)" do
    # One grapheme of 5001 bytes: over PostgreSQL's lexeme limit, never
    # indexed; the short words around it are.
    @marks "x" <> String.duplicate("\u0301", 2500)

    test "feedback with it is added and revised; the invariant holds", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x")
      {:ok, old} = Feedback.add(scope, task.ident, %{content: "#{@marks}-quokka deadlock"})
      assert ids(scope, "quokka") == [task.ident]
      assert ids(scope, "deadlock") == [task.ident]

      {:ok, new} =
        Feedback.revise(scope, "#{task.ident}##{old.seq}", %{content: "#{@marks} livelock"})

      assert ids(scope, "deadlock") == []
      assert ids(scope, "livelock") == [task.ident]
      assert ids(scope, @marks) == []
      assert Repo.one!(from(f in Entry, where: f.id == ^old.id, select: f.search)) == nil
      assert [_] = Repo.one!(from(f in Entry, where: f.id == ^new.id, select: f.search))
    end

    test "task titles, descriptions and labels with it; reindex too",
         %{scope: scope, workspace: workspace} do
      task =
        task_fixture(scope, "BOS",
          # Titles are at most 200 code points: 151 is still far over 64.
          title: "x#{String.duplicate("\u0301", 150)} wombat",
          labels: [@marks]
        )

      {:ok, _} = Tasks.update(scope, task.ident, %{description: "#{@marks}_platypus"})
      assert ids(scope, "wombat") == [task.ident]
      assert ids(scope, "platypus") == [task.ident]

      {:ok, _} = Feedback.add(scope, task.ident, %{content: @marks})
      Repo.update_all(where(Task, id: ^task.id), set: [search: nil])
      assert %{tasks: 1, feedback: 1, skipped: 0} = Search.Reindex.run(workspace: workspace.slug)
      assert ids(scope, "platypus") == [task.ident]
    end
  end

  describe "feedback" do
    setup %{scope: scope} do
      %{task: task_fixture(scope, "BOS", title: "x")}
    end

    test "修订后旧内容搜不到、新内容立即可搜", %{scope: scope, task: task} do
      {:ok, old} = Feedback.add(scope, task.ident, %{content: "found a deadlock"})
      assert ids(scope, "deadlock") == [task.ident]

      {:ok, new} =
        Feedback.revise(scope, "#{task.ident}##{old.seq}", %{content: "it was a livelock"})

      assert ids(scope, "deadlock") == []
      {:ok, [hit]} = Search.search(scope, "livelock")
      assert hit.feedback.id == "#{task.ident}##{new.seq}"
      assert new.seq == 2

      assert Repo.one!(from(f in Entry, where: f.id == ^old.id, select: f.search)) == nil
      assert Repo.one!(from(f in Entry, where: f.id == ^new.id, select: f.search)) != nil
    end

    test "修订回滚", %{scope: scope, task: task} do
      {:ok, old} = Feedback.add(scope, task.ident, %{content: "found a deadlock"})

      {:error, :rolled_back} =
        Tx.run(fn ->
          {:ok, _} = Feedback.revise(scope, "#{task.ident}##{old.seq}", %{content: "a livelock"})
          assert ids(scope, "livelock") == [task.ident]
          {:error, :rolled_back}
        end)

      assert ids(scope, "deadlock") == [task.ident]
      assert ids(scope, "livelock") == []
    end

    test "transition reasons, fallback replies and system notes are searchable",
         %{scope: scope, task: task, workspace: workspace} do
      {:ok, _} = Tasks.transition(scope, task.ident, :in_progress)

      {:ok, _} =
        Tasks.transition(scope, task.ident, :cancelled, %{
          feedback: %{content: "obsolete because of quokka"}
        })

      system =
        Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace.id and a.kind == :system))

      {:ok, _} =
        Tx.run(fn ->
          locked = Repo.one!(from(t in Task, where: t.id == ^task.id, lock: "FOR UPDATE"))

          {:ok, {_, locked}} =
            Feedback.insert_locked(locked, %Scope{actor: system}, %{content: "system wombat"})

          Feedback.insert_locked(locked, scope, %{content: "fallback platypus"}, fallback: true)
        end)

      for word <- ["quokka", "wombat", "platypus"], do: assert(ids(scope, word) == [task.ident])
    end

    property "active records always have a column, superseded ones never",
             %{scope: scope, task: task} do
      check all steps <-
                  list_of(
                    one_of([
                      tuple({constant(:add), string(:alphanumeric, min_length: 1)}),
                      tuple({constant(:revise), string(:alphanumeric, min_length: 1)}),
                      tuple({constant(:fallback), string(:alphanumeric, min_length: 1)})
                    ]),
                    max_length: 8
                  ),
                max_runs: 25 do
        Enum.each(steps, &step(scope, task, &1))

        assert Repo.aggregate(
                 from(f in Entry,
                   where: f.task_id == ^task.id and f.status == :active and is_nil(f.search)
                 ),
                 :count
               ) == 0

        assert Repo.aggregate(
                 from(f in Entry,
                   where:
                     f.task_id == ^task.id and f.status == :superseded and not is_nil(f.search)
                 ),
                 :count
               ) == 0
      end
    end
  end

  defp step(scope, task, {:add, content}),
    do: {:ok, _} = Feedback.add(scope, task.ident, %{content: content})

  defp step(scope, task, {:revise, content}) do
    case Repo.one(
           from(f in Entry,
             where: f.task_id == ^task.id and f.status == :active,
             order_by: [desc: f.seq],
             limit: 1,
             select: f.seq
           )
         ) do
      nil -> :ok
      seq -> {:ok, _} = Feedback.revise(scope, "#{task.ident}##{seq}", %{content: content})
    end
  end

  defp step(scope, task, {:fallback, content}) do
    {:ok, _} =
      Tx.run(fn ->
        locked = Repo.one!(from(t in Task, where: t.id == ^task.id, lock: "FOR UPDATE"))
        Feedback.insert_locked(locked, scope, %{content: content}, fallback: true)
      end)
  end
end

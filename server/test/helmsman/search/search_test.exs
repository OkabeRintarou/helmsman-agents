defmodule Helmsman.Search.SearchTest do
  # add-fulltext-search 1.5: search and ranking (decision 6).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Feedback, Projects, QueryCount, Search, Tasks}
  alias Helmsman.Search.Snippet
  alias Helmsman.Tasks.Task

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "KEEL")
    %{owner: owner, workspace: workspace, scope: scope}
  end

  defp ids(scope, query, opts \\ []) do
    {:ok, hits} = Search.search(scope, query, opts)
    Enum.map(hits, & &1.task.id)
  end

  # Gives the tasks the same `updated_at`, so only the rank orders them.
  defp same_time(tasks) do
    ids = Enum.map(tasks, & &1.id)
    Repo.update_all(where(Task, [t], t.id in ^ids), set: [updated_at: ~U[2026-01-01 00:00:00Z]])
  end

  describe "全文检索与排序" do
    test "标题优先于描述与 Feedback", %{scope: scope} do
      bos1 = task_fixture(scope, "BOS", title: "Connection timeout")
      bos2 = task_fixture(scope, "BOS", title: "Pool", description: "a timeout on start")
      bos3 = task_fixture(scope, "BOS", title: "Startup")
      {:ok, entry} = Feedback.add(scope, bos3.ident, %{content: "I saw a timeout too"})
      same_time([bos1, bos2, bos3])

      {:ok, [h1, h2, h3]} = Search.search(scope, "timeout")
      assert [h1.task.id, h2.task.id, h3.task.id] == ["BOS-1", "BOS-2", "BOS-3"]
      assert h1.rank > h2.rank and h2.rank > h3.rank

      assert h1.snippet == nil and h1.feedback == nil
      assert Snippet.to_text(h2.snippet) == "a **timeout** on start"
      assert h2.feedback == nil

      assert h3.snippet == nil

      assert %{id: "BOS-3#1", kind: "comment", author: %{name: _, kind: "human"}, snippet: s} =
               h3.feedback

      assert Snippet.to_text(s) == "I saw a **timeout** too"
      assert entry.seq == 1
    end

    test "a task matching itself and by feedback: the better source wins", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x", description: "deadlock")
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "a deadlock"})
      {:ok, [hit]} = Search.search(scope, "deadlock")
      assert hit.feedback == nil
      assert Snippet.to_text(hit.snippet) == "**deadlock**"

      # A record that ranks higher than the description is the source.
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "deadlock deadlock deadlock"})
      {:ok, [hit]} = Search.search(scope, "deadlock")
      assert hit.snippet == nil
      assert %{id: "BOS-1#2", snippet: [_ | _]} = hit.feedback
    end

    test "the best feedback record of a task is chosen", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x")
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "one quokka"})
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "quokka quokka here"})
      {:ok, [hit]} = Search.search(scope, "quokka")
      assert hit.feedback.id == "BOS-1#2"
    end

    test "同分按更新时间降序", %{scope: scope} do
      a = task_fixture(scope, "BOS", title: "same words")
      b = task_fixture(scope, "BOS", title: "same words")
      {:ok, _} = Tasks.update(scope, a.ident, %{priority: "high"})
      assert ids(scope, "same words") == [a.ident, b.ident]
    end

    test "中文须相邻", %{scope: scope} do
      task_fixture(scope, "BOS", title: "x", description: "管理任务")
      ok = task_fixture(scope, "BOS", title: "任务管理系统")
      assert ids(scope, "任务管理") == [ok.ident]
      assert ids(scope, "管理任务") == ["BOS-1"]
    end

    test "a single CJK character matches the bigrams starting with it", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "登录")
      assert ids(scope, "登") == [task.ident]
      assert ids(scope, "录") == []
    end

    test "边输边搜", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x", description: "found a deadlock")
      assert ids(scope, "deadl") == [task.ident]
      assert ids(scope, "deadl x") == []
      assert ids(scope, "x deadl") == [task.ident]
    end

    test "groups are ANDed", %{scope: scope} do
      both = task_fixture(scope, "BOS", title: "login timeout")
      task_fixture(scope, "BOS", title: "login only")
      assert ids(scope, "timeout login") == [both.ident]
    end

    test "labels and ID fragments are searchable", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x", labels: ["backend"])
      task_fixture(scope, "KEEL", title: "y")
      assert ids(scope, "backend") == [task.ident]
      assert ids(scope, "bos") == [task.ident]
    end

    test "ID 直达", %{scope: scope} do
      for _ <- 1..11, do: task_fixture(scope, "BOS", title: "filler")
      bos12 = task_fixture(scope, "BOS", title: "the target")
      other = task_fixture(scope, "BOS", title: "see bos-12 bos-12 bos-12")
      assert bos12.ident == "BOS-12"

      assert [first | rest] = ids(scope, "bos-12")
      assert first == "BOS-12"
      assert other.ident in rest

      {:ok, [hit | _]} = Search.search(scope, " BOS-12 ")
      assert hit.task.id == "BOS-12"
      # It matches its own ID too: a text hit, kept with its rank.
      assert hit.rank > 0
    end

    test "ID 直达 without a text hit, limit included", %{scope: scope} do
      task_fixture(scope, "BOS", title: "a")
      task_fixture(scope, "BOS", title: "b")
      # Only the ID: the column is emptied, as before a reindex.
      Repo.update_all(where(Task, ident: "BOS-2"), set: [search: nil])

      {:ok, [hit]} = Search.search(scope, "BOS-2", limit: 1)
      assert %{task: %{id: "BOS-2"}, rank: +0.0, snippet: nil, feedback: nil} = hit
      assert ids(scope, "BOS-2") == ["BOS-2"]
      assert ids(scope, "BOS-9") == []
      assert ids(scope, "BOS-2", project_key: "KEEL") == []
    end

    test "工作区隔离", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "修复登录超时")
      other_owner = user_fixture()
      other = workspace_scope_fixture(other_owner, workspace_fixture(other_owner))
      project_fixture(other, key: "BOS")
      twin = task_fixture(other, "BOS", title: "修复登录超时")
      {:ok, _} = Feedback.add(other, twin.ident, %{content: "修复登录超时"})

      assert ids(scope, "登录") == [task.ident]
      assert ids(scope, "BOS-1") == [task.ident]
      assert ids(other, "登录") == [twin.ident]
    end

    test "project filter and 项目不存在", %{scope: scope} do
      bos = task_fixture(scope, "BOS", title: "shared word")
      keel = task_fixture(scope, "KEEL", title: "shared")
      {:ok, _} = Feedback.add(scope, keel.ident, %{content: "word"})
      assert ids(scope, "shared", project_key: "bos") == [bos.ident]
      assert ids(scope, "word", project_key: "KEEL") == [keel.ident]
      assert {:error, :not_found} = Search.search(scope, "shared", project_key: "NOPE")
    end

    test "archived projects stay searchable", %{scope: scope} do
      task = task_fixture(scope, "KEEL", title: "archived quokka")
      {:ok, _} = Projects.archive(scope, "KEEL")
      assert ids(scope, "quokka") == [task.ident]
    end

    test "superseded feedback is not found", %{scope: scope} do
      task = task_fixture(scope, "BOS", title: "x")
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "deadlock"})
      {:ok, _} = Feedback.revise(scope, "BOS-1#1", %{content: "fine now"})
      assert ids(scope, "deadlock") == []
    end

    test "blank, too long, not a string, stop words only", %{scope: scope} do
      task_fixture(scope, "BOS", title: "the")
      assert {:ok, []} = Search.search(scope, "   ")
      assert {:ok, []} = Search.search(scope, "the a 的")
      assert {:ok, [%{task: %{id: "BOS-1"}}]} = Search.search(scope, "BOS-1")

      assert {:error, {:invalid_query, :too_long}} =
               Search.search(scope, String.duplicate("x", 201))

      assert {:error, {:invalid_query, :not_a_string}} = Search.search(scope, nil)
    end

    test "limit: default 20, at most 50", %{scope: scope} do
      for _ <- 1..55, do: task_fixture(scope, "BOS", title: "many")
      assert length(ids(scope, "many")) == 20
      assert length(ids(scope, "many", limit: 5)) == 5
      assert length(ids(scope, "many", limit: 500)) == 50
    end

    test "results carry the task summary", %{scope: scope} do
      task_fixture(scope, "BOS", title: "summary check", labels: ["ui"])
      {:ok, [hit]} = Search.search(scope, "summary")
      assert %{id: "BOS-1", project_key: "BOS", status: "new", labels: ["ui"]} = hit.task
      assert Map.has_key?(hit.task, :assignee)
    end
  end

  describe "access" do
    test "viewers and run tokens search; non-members are forbidden" do
      ctx = dispatch_fixture()
      task = task_fixture(ctx.alice_scope, ctx.project.key, title: "quokka")
      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

      run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
      {run_scope, _token} = run_scope_fixture(run)

      for scope <- [viewer_scope, run_scope] do
        assert {:ok, [%{task: %{id: id}}]} = Search.search(scope, "quokka")
        assert id == task.ident
      end

      assert {:error, :forbidden} = Search.search(%{viewer_scope | role: nil}, "quokka")
    end
  end

  describe "query count" do
    test "the same for 1 hit and for 50", %{scope: scope} do
      task_fixture(scope, "KEEL", title: "single")
      {:ok, _} = Feedback.add(scope, "KEEL-1", %{content: "single in feedback"})

      for _ <- 1..50 do
        task = task_fixture(scope, "BOS", title: "plenty")
        {:ok, _} = Feedback.add(scope, task.ident, %{content: "plenty plenty plenty"})
      end

      {{:ok, one}, n1} = QueryCount.count(fn -> Search.search(scope, "single") end)
      {{:ok, fifty}, n50} = QueryCount.count(fn -> Search.search(scope, "plenty", limit: 50) end)
      assert length(one) == 1 and length(fifty) == 50
      assert n1 == n50
    end
  end
end

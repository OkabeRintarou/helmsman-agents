defmodule HelmsmanWeb.TaskLive.HistoryTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Repo, Tasks}

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, ws)
    project_fixture(scope, key: "BOS", name: "Bosun")
    task_fixture(scope, "BOS")
    %{conn: log_in_user(conn, owner), scope: scope, path: "/w/#{ws.slug}/t/BOS-1"}
  end

  test "the creation entry", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#history-0", "创建了任务")
    assert has_element?(view, "#history-0 [data-actor-kind=human]")
    assert has_element?(view, "#history-0 time")
  end

  test "an entry with commits and tests", %{conn: conn, path: path, scope: scope} do
    {:ok, _} = Tasks.transition(scope, "BOS-1", "in_progress", %{})

    {:ok, _} =
      Tasks.transition(scope, "BOS-1", "done", %{
        commits: ["abc1234def"],
        tests: %{command: "mix test", passed: true, summary: "42 tests, 0 failures"}
      })

    {:ok, view, _html} = live(conn, path)
    entry = "#history-2"

    assert has_element?(view, entry <> " [data-from]", "进行中")
    assert has_element?(view, entry <> " [data-to]", "待验收")
    assert has_element?(view, entry <> " code.font-mono", "abc1234")
    refute has_element?(view, entry <> " code", "abc1234def")
    assert has_element?(view, entry <> ~s( button[data-copy="abc1234def"]))
    assert has_element?(view, entry <> ~s( [data-tests] [aria-label="测试通过"]))
    assert has_element?(view, entry <> " [data-tests] code", "mix test")
    assert has_element?(view, entry <> " [data-tests]", "42 tests, 0 failures")
    assert has_element?(view, "#task-commits code", "abc1234")
  end

  test "automatic entries are marked", %{conn: conn, path: path, scope: scope} do
    {:ok, task} = Tasks.get(scope, "BOS-1")

    Repo.insert!(%Tasks.TaskEvent{
      workspace_id: task.workspace_id,
      task_id: task.id,
      from_status: :new,
      to_status: :in_progress,
      actor_id: scope.actor.id,
      commits: [],
      auto: true
    })

    Repo.update!(Ecto.Changeset.change(task, status: :in_progress))

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#history-1 [data-auto]", "自动")
    refute has_element?(view, "#history-0 [data-auto]")
  end

  test "entries without commits, tests or auto still render" do
    html =
      render_component(&HelmsmanWeb.TaskComponents.history_entry/1,
        id: "h",
        entry: %{
          from: "new",
          to: "in_progress",
          actor: %{name: "alice", kind: "human"},
          comment: "go",
          at: ~U[2026-01-01 00:00:00Z]
        },
        now: ~U[2026-01-02 00:00:00Z]
      )

    assert html =~ "新建"
    assert html =~ "进行中"
    assert html =~ "go"
    refute html =~ "data-auto"
    refute html =~ "data-tests"
  end

  test "an agent's entry is 托管 / 外接 from `agents`, neither without an entry" do
    entry = fn name ->
      %{
        from: "new",
        to: "in_progress",
        actor: %{name: name, kind: "agent"},
        at: ~U[2026-01-01 00:00:00Z]
      }
    end

    agents = %{"keel/dev" => %{managed?: true}, "alice/cli" => %{managed?: false}}

    render = fn name ->
      render_component(&HelmsmanWeb.TaskComponents.history_entry/1,
        id: "h",
        entry: entry.(name),
        agents: agents,
        now: ~U[2026-01-02 00:00:00Z]
      )
    end

    assert render.("keel/dev") =~ "托管"
    refute render.("keel/dev") =~ "外接"
    assert render.("alice/cli") =~ "外接"
    refute render.("gone/agent") =~ ~r/托管|外接/
  end

  test "an entry with a reason links to its feedback; old entries keep their comment",
       %{conn: conn, path: path, scope: scope} do
    {:ok, _} = Tasks.transition(scope, "BOS-1", "in_progress", %{comment: "旧的备注"})

    {:ok, _} =
      Tasks.transition(scope, "BOS-1", "cancelled", %{feedback: %{kind: "comment", content: "重复"}})

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#history-1 [data-comment]", "旧的备注")
    refute has_element?(view, "#history-1 [data-reason]")

    assert has_element?(view, "#history-2 [data-reason]", "原因：")
    assert has_element?(view, ~s(#history-2 [data-reason] a[href="#feedback-1"]), "BOS-1#1")
    refute has_element?(view, "#history-2 [data-comment]")
  end
end

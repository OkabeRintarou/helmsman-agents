defmodule HelmsmanWeb.TaskLive.IdleHintTest do
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Helmsman.AgentsFixtures, only: [managed_agent_fixture: 2]
  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.{Actors, Agents, Dispatch, Feedback, Repo, Tasks}

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "等待 Agent 开工"})
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev", start: false})
    {:ok, _} = Tasks.transition(ctx.alice_scope, task.ident, :in_progress)

    Map.merge(ctx, %{conn: conn, task: task, path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"})
  end

  defp open(ctx, user \\ nil), do: live(log_in_user(ctx.conn, user || ctx.alice), ctx.path)

  test "idle managed agent gets an explanation and a working launch button", ctx do
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#task-idle-hint", "进行中，但没有运行在处理：改状态不会启动 Agent。")
    assert has_element?(view, "#start-idle-agent", "让 keel/dev 开工")
    refute render(view) =~ "已改为进行中。"

    view |> element("#start-idle-agent") |> render_click()
    assert [run] = runs_of(ctx.task.id)
    assert run.status == :queued
    assert [%{"kind" => "manual"}] = run.triggers
    assert has_element?(view, "#run-card-#{run.id}")
    refute has_element?(view, "#task-idle-hint")
    assert has_element?(view, "#flash-info", "已派发给 keel/dev")
  end

  for status <- [:new, :done, :verified, :cancelled] do
    test "no hint in #{status}", ctx do
      Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id),
        set: [status: unquote(status)]
      )

      {:ok, view, _} = open(ctx)
      refute has_element?(view, "#task-idle-hint")
    end
  end

  test "epics are excluded", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.task, kind: :epic))
    {:ok, view, _} = open(ctx)
    refute has_element?(view, "#task-idle-hint")
  end

  test "unassigned, human and external agent tasks are excluded", ctx do
    external = agent_fixture(ctx.workspace, ctx.alice, "outside/cli")
    human = Actors.get_human(ctx.workspace.id, ctx.alice.id)

    for assignee <- [nil, human.name, external.name] do
      {:ok, _} =
        Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: assignee, start: false})

      {:ok, view, _} = open(ctx)
      refute has_element?(view, "#task-idle-hint")
    end
  end

  for status <- [:queued, :deferred, :claimed, :running, :cancelling] do
    test "#{status} runs suppress the hint, including another agent's run", ctx do
      other = managed_agent_fixture(ctx.alice_scope, %{name: "keel/other"})

      run_fixture(agent_actor(ctx.workspace, other.name), %{
        task_id: ctx.task.id,
        status: unquote(status)
      })

      {:ok, view, _} = open(ctx)
      refute has_element?(view, "#task-idle-hint")
    end
  end

  for status <- [:succeeded, :failed, :cancelled] do
    test "finished #{status} history does not suppress the hint", ctx do
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: unquote(status),
        finished_at: DateTime.utc_now()
      })

      {:ok, view, _} = open(ctx)
      assert has_element?(view, "#task-idle-hint")
    end
  end

  test "open questions hide the hint and answering restores it live", ctx do
    {:ok, view, _} = open(ctx)

    {:ok, _} =
      Feedback.add(ctx.alice_scope, ctx.task.ident, %{kind: :question, content: "用哪个方案？"})

    eventually(fn -> not has_element?(view, "#task-idle-hint") end)
    assert has_element?(view, "#task-open-question")
    {:ok, _} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{kind: :answer, content: "方案 A"})
    eventually(fn -> has_element?(view, "#task-idle-hint") end)
  end

  test "a run from another window hides the hint and its end restores it", ctx do
    {:ok, view, _} = open(ctx)
    pid = view.pid
    {:ok, %{run: run}} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, nil)
    eventually(fn -> not has_element?(view, "#task-idle-hint") end)

    Repo.update_all(Ecto.Query.from(r in Helmsman.Runs.Run, where: r.id == ^run.id),
      set: [status: :cancelled, finished_at: DateTime.utc_now()]
    )

    send(view.pid, {:runs_changed, ctx.task.ident})
    eventually(fn -> has_element?(view, "#task-idle-hint") end)
    assert view.pid == pid
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: nil})
    eventually(fn -> not has_element?(view, "#task-idle-hint") end)
  end

  test "viewer and owner-only access cannot launch, even by forged event", ctx do
    for {role, access} <- [{:viewer, "workspace"}, {:member, "owner_only"}] do
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: access})
      {user, _} = member_scope_fixture(ctx.workspace, role)
      {:ok, view, _} = open(ctx, user)
      assert has_element?(view, "#task-idle-hint")
      refute has_element?(view, "#start-idle-agent")
      render_click(view, "start_idle_agent", %{})
      assert runs_of(ctx.task.id) == []
      assert render(view) =~ "没有权限执行此操作"
    end
  end

  test "workspace members can launch and permission changes are rechecked", ctx do
    {user, _} = member_scope_fixture(ctx.workspace)
    {:ok, view, _} = open(ctx, user)
    assert has_element?(view, "#start-idle-agent")
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: "owner_only"})
    eventually(fn -> not has_element?(view, "#start-idle-agent") end)
    render_click(view, "start_idle_agent", %{})
    assert runs_of(ctx.task.id) == []
  end

  test "disabled agent cannot launch; unavailable runtime explains skipped outcome", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#task-idle-hint")
    refute has_element?(view, "#start-idle-agent")
    {:ok, _} = Agents.enable(ctx.alice_scope, "keel/dev")
    Repo.update!(Ecto.Changeset.change(profile(ctx.agent), runtime_id: nil))
    send(view.pid, {:agents_changed})
    eventually(fn -> has_element?(view, "#start-idle-agent") end)
    view |> element("#start-idle-agent") |> render_click()
    assert render(view) =~ "没有启动 keel/dev：它没有绑定运行时"
    assert has_element?(view, "#task-idle-hint")
    assert runs_of(ctx.task.id) == []
  end

  test "squad explains assignment and mention, without a run_agent button", ctx do
    squad = squad_fixture(ctx.alice_scope, %{name: "web-team", leader: "keel/dev"})

    {:ok, _} =
      Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: squad.name, start: false})

    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#task-idle-hint", "重新指派给小队，或在 Feedback 里 @web-team 启动 leader")
    refute has_element?(view, "#start-idle-agent")
    render_click(view, "start_idle_agent", %{})
    assert runs_of(ctx.task.id) == []
  end

  test "squad transition flash gives squad actions rather than an unavailable button", ctx do
    squad_fixture(ctx.alice_scope, %{name: "web-team", leader: "keel/dev"})

    {:ok, _} =
      Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "web-team", start: false})

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :new])
    {:ok, view, _} = open(ctx)
    view |> element("#transition-in_progress") |> render_click()
    assert has_element?(view, "#flash-info", "改状态不会启动 web-team。重新指派给小队")
    refute has_element?(view, "#start-idle-agent")
  end

  test "a stale launch event does not start a second run", ctx do
    {:ok, view, _} = open(ctx)
    {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, nil)
    render_click(view, "start_idle_agent", %{})
    assert [run] = runs_of(ctx.task.id)
    assert length(run.triggers) == 1
    refute has_element?(view, "#task-idle-hint")
  end

  test "archived managed agent still gets a hint without a launch button", ctx do
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#task-idle-hint")
    refute has_element?(view, "#start-idle-agent")
  end

  test "changing NEW to IN_PROGRESS explains that it did not launch an agent", ctx do
    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :new])
    {:ok, view, _} = open(ctx)
    view |> element("#transition-in_progress") |> render_click()
    assert render(view) =~ "已改为进行中。改状态不会启动 keel/dev，需要时点「让 keel/dev 开工」。"
    assert has_element?(view, "#task-idle-hint")
    assert runs_of(ctx.task.id) == []
  end

  test "owner-only member transition flash does not suggest an unavailable launch button", ctx do
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: "owner_only"})
    {user, _} = member_scope_fixture(ctx.workspace, :member)
    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :new])
    {:ok, view, _} = open(ctx, user)
    view |> element("#transition-in_progress") |> render_click()
    assert has_element?(view, "#flash-info", "已改为进行中。改状态不会启动 keel/dev。")
    refute has_element?(view, "#flash-info", "需要时点")
    refute has_element?(view, "#start-idle-agent")
    assert runs_of(ctx.task.id) == []
  end

  test "disabled agent transition flash does not suggest an unavailable launch button", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :new])
    {:ok, view, _} = open(ctx)
    view |> element("#transition-in_progress") |> render_click()
    assert has_element?(view, "#flash-info", "已改为进行中。改状态不会启动 keel/dev。")
    refute has_element?(view, "#flash-info", "需要时点")
    refute has_element?(view, "#start-idle-agent")
    assert runs_of(ctx.task.id) == []
  end

  test "transition with a pending run has no idle flash", ctx do
    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :new])
    run_fixture(ctx.agent, %{task_id: ctx.task.id})
    {:ok, view, _} = open(ctx)
    view |> element("#transition-in_progress") |> render_click()
    refute render(view) =~ "已改为进行中。改状态不会启动"
    refute has_element?(view, "#task-idle-hint")
  end
end

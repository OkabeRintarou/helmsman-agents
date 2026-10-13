defmodule Helmsman.Dispatch.DependencySweepTest do
  # add-dependency-dispatch 1.9: the sweep selects only runs to act on now
  # (decision 9).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.DependencyFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Dispatch.Workers.DependencySweep
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.Links.Link
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    prereq = task_fixture(ctx.alice_scope, ctx.project.key)
    put_status!(prereq, :in_progress)
    Map.put(ctx, :prereq, prereq)
  end

  @old ~U[2026-01-01 00:00:00.000000Z]

  # `n` tasks of keel/dev, each with a deferred `assign` run (updated at
  # `updated_at`), depending on `prereq` when given. Bulk inserts.
  defp deferred_tasks(ctx, n, opts) do
    now = DateTime.utc_now()
    # The project's next sequence numbers (`tasks.seq` is an int4), taken
    # from its counter so that later tasks do not collide.
    {1, [last]} =
      Repo.update_all(
        from(p in Project, where: p.id == ^ctx.project.id, select: p.task_seq),
        inc: [task_seq: n]
      )

    base = last - n

    {_, tasks} =
      Repo.insert_all(
        Task,
        for i <- 1..n do
          %{
            workspace_id: ctx.workspace.id,
            project_id: ctx.project.id,
            seq: base + i,
            ident: "#{ctx.project.key}-#{base + i}",
            title: "T",
            created_by_id: ctx.alice_scope.actor.id,
            assignee_id: ctx.agent.id,
            inserted_at: now,
            updated_at: now
          }
        end,
        returning: [:id]
      )

    if prereq = opts[:prereq] do
      Repo.insert_all(
        Link,
        for t <- tasks do
          %{
            workspace_id: ctx.workspace.id,
            from_task_id: t.id,
            to_task_id: prereq.id,
            type: :depends_on,
            actor_id: ctx.alice_scope.actor.id
          }
        end
      )
    end

    trigger = trigger("assign", ctx.workspace, ctx.alice, ctx.agent)
    profile = profile(ctx.agent)

    {_, runs} =
      Repo.insert_all(
        Run,
        for t <- tasks do
          %{
            workspace_id: ctx.workspace.id,
            agent_id: ctx.agent.id,
            runtime_id: profile.runtime_id,
            task_id: t.id,
            lane: :work,
            status: :deferred,
            triggers: [trigger],
            root_initiator_user_id: ctx.alice.id,
            causal_agent_ids: [ctx.agent.id],
            capabilities: ["read", "write_task"],
            priority: 2,
            not_before: opts[:updated_at],
            inserted_at: opts[:updated_at],
            updated_at: opts[:updated_at]
          }
        end,
        returning: [:id, :updated_at]
      )

    runs
  end

  defp statuses(runs) do
    ids = Enum.map(runs, & &1.id)

    Repo.all(from(r in Run, where: r.id in ^ids, select: {r.status, r.updated_at}))
    |> Enum.frequencies_by(&elem(&1, 0))
  end

  defp sweep, do: perform_job(DependencySweep, %{})

  test "解绑仓库后清扫", ctx do
    installation = installation_fixture(ctx.workspace)
    repo = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repo)
    put_status!(ctx.prereq, :done)

    run_fixture(ctx.agent, %{
      task_id: ctx.prereq.id,
      status: :succeeded,
      repository_id: repo.id,
      claimed_at: DateTime.utc_now(),
      branch: "b",
      base_sha: String.duplicate("0", 40),
      head_sha: String.duplicate("c", 40),
      push_status: :pushed,
      pushed_at: DateTime.utc_now()
    })

    Repo.insert!(%PullRequest{
      workspace_id: ctx.workspace.id,
      task_id: ctx.prereq.id,
      repository_id: repo.id,
      number: 1,
      node_id: "n",
      url: "u",
      branch: "b",
      base_branch: "main",
      state: :open
    })

    [web2] = deferred_tasks(ctx, 1, prereq: ctx.prereq, updated_at: @old)
    assert :ok = sweep()
    assert run_status(web2) == :deferred

    Repo.update_all(from(p in Project, where: p.id == ^ctx.project.id), set: [repository_id: nil])
    assert :ok = sweep()

    run = Repo.get!(Run, web2.id)
    assert run.status == :queued
    assert %{"kind" => "unblocked", "prerequisites" => [_]} = List.last(run.triggers)
  end

  test "长期阻塞的运行不占清扫名额", ctx do
    blocked = deferred_tasks(ctx, 600, prereq: ctx.prereq, updated_at: @old)
    later = DateTime.add(@old, 3600, :second)
    [web2] = deferred_tasks(ctx, 1, prereq: ctx.prereq, updated_at: later)
    # Its dependency is gone (as after a binding change): nothing woke it.
    Repo.delete_all(from(l in Link, where: l.from_task_id == ^Repo.get!(Run, web2.id).task_id))

    assert :ok = sweep()

    assert run_status(web2) == :queued
    ids = Enum.map(blocked, & &1.id)

    assert Repo.all(from(r in Run, where: r.id in ^ids, select: {r.status, r.updated_at}))
           |> Enum.uniq() == [{:deferred, @old}]
  end

  test "1200 releasable runs in one round (three batches)", ctx do
    runs = deferred_tasks(ctx, 1200, updated_at: @old)
    assert Dependencies.sweep() == 1200
    assert statuses(runs) == %{queued: 1200}
  end

  test "obsolete runs are cancelled; others not selected", ctx do
    [cancelled, reassigned, blocked, released] =
      for _ <- 1..4, do: hd(deferred_tasks(ctx, 1, prereq: ctx.prereq, updated_at: @old))

    task_of = fn run -> %{id: Repo.get!(Run, run.id).task_id} end
    put_status!(task_of.(cancelled), :cancelled)
    put_assignee!(task_of.(reassigned), nil)
    Repo.delete_all(from(l in Link, where: l.from_task_id == ^task_of.(released).id))

    autopilot_task = task_fixture(ctx.alice_scope, ctx.project.key)
    autopilot = run_with!(ctx, autopilot_task, :deferred, ["autopilot"])

    assert Dependencies.sweep() == 3

    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, cancelled.id)
    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, reassigned.id)
    assert run_status(blocked) == :deferred
    assert run_status(released) == :queued
    assert run_status(autopilot) == :deferred
  end

  test "every ten minutes (crontab)" do
    plugins = Application.fetch_env!(:helmsman, Oban)[:plugins]
    {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
    assert {"*/10 * * * *", DependencySweep} in opts[:crontab]
  end
end

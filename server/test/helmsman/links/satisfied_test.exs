defmodule Helmsman.Links.SatisfiedTest do
  # add-dependency-dispatch 1.2: the full definition of a satisfied
  # prerequisite (decision 2), task-links「依赖满足与被阻塞」, and the
  # property test against a reference model written from decision 2.
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.GitHub.PullRequest
  alias Helmsman.Links
  alias Helmsman.Links.Link
  alias Helmsman.LocalRepositories.TaskLocalBranch
  alias Helmsman.Projects.Project
  alias Helmsman.QueryCount
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    installation = installation_fixture(ctx.workspace)
    gh = repository_fixture(installation, %{owner: "acme", name: "app"})
    gh_other = repository_fixture(installation, %{owner: "acme", name: "old"})
    daemon = daemon_of(ctx.agent)
    local = local_repository_fixture(ctx.workspace, daemon, %{name: "app"})
    local_other = local_repository_fixture(ctx.workspace, daemon, %{name: "old"})

    Map.merge(ctx, %{
      daemon: daemon,
      repos: %{gh: gh, gh_other: gh_other, local: local, local_other: local_other}
    })
  end

  ## Helpers

  defp new_task(ctx, attrs \\ %{}), do: task_fixture(ctx.alice_scope, ctx.project.key, attrs)

  defp put_status!(%{id: id}, status),
    do: Repo.update_all(from(t in Task, where: t.id == ^id), set: [status: status])

  defp bind!(ctx, :none), do: set_binding(ctx, nil, nil)
  defp bind!(ctx, :github), do: set_binding(ctx, ctx.repos.gh.id, nil)
  defp bind!(ctx, :local), do: set_binding(ctx, nil, ctx.repos.local.id)

  defp set_binding(ctx, repository_id, local_repository_id),
    do:
      Repo.update_all(from(p in Project, where: p.id == ^ctx.project.id),
        set: [repository_id: repository_id, local_repository_id: local_repository_id]
      )

  defp sha(c), do: String.duplicate(c, 40)

  @base ~U[2026-10-01 00:00:00.000000Z]

  # A run of `task` that delivered `head` to `target` (`:gh`, `:gh_other`,
  # `:local`, `:local_other`), claimed `offset` seconds after a fixed time.
  defp delivery!(ctx, task, target, head, opts \\ []) do
    repo = Map.fetch!(ctx.repos, target)
    conflict? = Keyword.get(opts, :conflict, false)

    column =
      if target in [:gh, :gh_other], do: :repository_id, else: :local_repository_id

    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          task_id: task.id,
          status: :succeeded,
          daemon_id: ctx.daemon.id,
          claimed_at: DateTime.add(@base, Keyword.get(opts, :offset, 0), :second),
          finished_at: @base,
          branch: "helmsman/x",
          base_sha: sha("0"),
          head_sha: head,
          push_status: if(conflict?, do: :conflict, else: :pushed),
          rescue_branch: if(conflict?, do: "helmsman/x-run-1"),
          push_commits: [],
          pushed_at: @base
        },
        %{column => repo.id}
      )
    )
  end

  defp active_run!(ctx, task, status \\ :running),
    do:
      run_fixture(ctx.agent, %{
        task_id: task.id,
        status: status,
        daemon_id: ctx.daemon.id,
        claimed_at: @base
      })

  defp pr!(ctx, task, target, state, included) do
    repo = Map.fetch!(ctx.repos, target)
    number = System.unique_integer([:positive])

    Repo.insert!(%PullRequest{
      workspace_id: ctx.workspace.id,
      task_id: task.id,
      repository_id: repo.id,
      number: number,
      node_id: "PR_#{number}",
      url: "https://github.com/acme/app/pull/#{number}",
      branch: "helmsman/x",
      base_branch: "main",
      state: state,
      merged_at: if(state == :merged, do: DateTime.utc_now()),
      included_sha: included
    })
  end

  defp local_branch!(ctx, task, target, state, head) do
    Repo.insert!(%TaskLocalBranch{
      workspace_id: ctx.workspace.id,
      task_id: task.id,
      local_repository_id: Map.fetch!(ctx.repos, target).id,
      branch: "helmsman/x",
      head_sha: head,
      state: state,
      merged_at: if(state == "merged", do: DateTime.utc_now(:second))
    })
  end

  defp depends!(ctx, from, to),
    do: {:ok, _} = Links.add(ctx.alice_scope, from.ident, to.ident, "depends_on")

  defp blocked?(ctx, task) do
    {:ok, task} = Tasks.get(ctx.alice_scope, task.ident)
    Tasks.summary(task).blocked
  end

  defp link_waiting_for(dependent, prereq) do
    dependent
    |> Repo.reload!()
    |> Links.for_task()
    |> Enum.find(&(&1.task == prereq.ident and &1.direction == "out"))
    |> Map.fetch!(:waiting_for)
  end

  ## Scenarios (task-links「依赖满足与被阻塞」)

  describe "#31 scenarios" do
    test "被阻塞不能开始 / 前置完成后", ctx do
      [bos1, web2] = [new_task(ctx), new_task(ctx)]
      put_status!(bos1, :in_progress)
      depends!(ctx, web2, bos1)

      assert Tasks.transition(ctx.alice_scope, web2.ident, "in_progress") ==
               {:error, {:blocked, [bos1.ident]}}

      assert link_waiting_for(web2, bos1) == "status"

      {:ok, _} = Tasks.transition(ctx.alice_scope, bos1.ident, "done")
      refute blocked?(ctx, web2)
      assert link_waiting_for(web2, bos1) == nil

      assert {:ok, %{status: "in_progress"}} =
               Tasks.transition(ctx.alice_scope, web2.ident, "in_progress")
    end

    test "已在进行中不受影响", ctx do
      [bos3, web2] = [new_task(ctx), new_task(ctx)]
      {:ok, _} = Tasks.transition(ctx.alice_scope, web2.ident, "in_progress")
      depends!(ctx, web2, bos3)
      assert {:ok, %{status: "done"}} = Tasks.transition(ctx.alice_scope, web2.ident, "done")
    end

    test "自动领取不检查", ctx do
      [bos1, web2] = [new_task(ctx), new_task(ctx)]
      depends!(ctx, web2, bos1)
      {:ok, _} = Tasks.update(ctx.alice_scope, web2.ident, %{assignee: "keel/dev", start: false})
      run = run_fixture(ctx.agent, %{task_id: web2.id, status: :running})
      assert Tasks.auto_claim_for_run(run) == {:ok, :claimed}
      assert Repo.reload!(web2).status == :in_progress
    end
  end

  describe "the code delivered (decision 2.3)" do
    setup ctx do
      [bos1, web2] = [new_task(ctx), new_task(ctx)]
      depends!(ctx, web2, bos1)
      Map.merge(ctx, %{bos1: bos1, web2: web2})
    end

    test "已验收但 PR 未合并", ctx do
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh, sha("c"))
      put_status!(ctx.bos1, :verified)
      pr = pr!(ctx, ctx.bos1, :gh, :open, nil)

      assert blocked?(ctx, ctx.web2)
      assert link_waiting_for(ctx.web2, ctx.bos1) == "merge"

      Repo.update_all(from(p in PullRequest, where: p.id == ^pr.id),
        set: [state: :merged, merged_at: DateTime.utc_now(), included_sha: sha("c")]
      )

      refute blocked?(ctx, ctx.web2)
      assert link_waiting_for(ctx.web2, ctx.bos1) == nil
    end

    test "已交付但还没有 PR", ctx do
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh, sha("c"))
      put_status!(ctx.bos1, :done)
      assert Links.waiting_for(ctx.bos1) == :merge
      assert Links.blockers(ctx.web2.id) == [ctx.bos1.ident]
    end

    test "运行中途置 DONE", ctx do
      put_status!(ctx.bos1, :done)
      active_run!(ctx, ctx.bos1)
      assert Links.waiting_for(ctx.bos1) == :run
      assert link_waiting_for(ctx.web2, ctx.bos1) == "run"
    end

    test "only claimed, running and cancelling runs count", ctx do
      put_status!(ctx.bos1, :done)

      for status <- [:claimed, :cancelling] do
        run = active_run!(ctx, ctx.bos1, status)
        assert Links.waiting_for(ctx.bos1) == :run
        Repo.delete!(run)
      end

      run_fixture(ctx.agent, %{task_id: ctx.bos1.id, status: :queued})
      assert Links.waiting_for(ctx.bos1) == nil
    end

    test "合并后又有新交付", ctx do
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh, sha("c"), offset: 1)
      pr!(ctx, ctx.bos1, :gh, :merged, sha("c"))
      delivery!(ctx, ctx.bos1, :gh, sha("d"), offset: 2)
      put_status!(ctx.bos1, :done)
      assert Links.waiting_for(ctx.bos1) == :merge
    end

    test "人补了提交后在 GitHub 上合并", ctx do
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh, sha("1"))
      pr = pr!(ctx, ctx.bos1, :gh, :merged, sha("1"))
      Repo.update_all(from(p in PullRequest, where: p.id == ^pr.id), set: [merged_sha: sha("2")])
      put_status!(ctx.bos1, :verified)
      assert Links.satisfied?(ctx.bos1)
    end

    test "合并前领取、合并后才推送", ctx do
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh, sha("1"), offset: 1)
      pr!(ctx, ctx.bos1, :gh, :merged, sha("1"))
      # Claimed before the merge (offset 2 < any later claim), pushed C3 after.
      delivery!(ctx, ctx.bos1, :gh, sha("3"), offset: 2)
      put_status!(ctx.bos1, :done)

      assert blocked?(ctx, ctx.web2)
      assert link_waiting_for(ctx.web2, ctx.bos1) == "merge"
    end

    test "本地仓库", ctx do
      bind!(ctx, :local)
      delivery!(ctx, ctx.bos1, :local, sha("c"), offset: 1)
      branch = local_branch!(ctx, ctx.bos1, :local, "merged", sha("c"))
      put_status!(ctx.bos1, :verified)
      assert Links.satisfied?(ctx.bos1)

      delivery!(ctx, ctx.bos1, :local, sha("d"), offset: 2)
      assert Links.waiting_for(ctx.bos1) == :merge

      branch |> Ecto.Changeset.change(head_sha: sha("d")) |> Repo.update!()
      assert Links.satisfied?(ctx.bos1)
    end

    test "绑定了仓库但没有交付", ctx do
      bind!(ctx, :github)
      put_status!(ctx.bos1, :done)
      assert Links.satisfied?(ctx.bos1)
    end

    test "only the repository bound now; a rescue-only push is no delivery", ctx do
      put_status!(ctx.bos1, :done)
      bind!(ctx, :github)
      delivery!(ctx, ctx.bos1, :gh_other, sha("c"))
      delivery!(ctx, ctx.bos1, :gh, sha("d"), conflict: true)
      assert Links.satisfied?(ctx.bos1)

      bind!(ctx, :none)
      delivery!(ctx, ctx.bos1, :gh, sha("e"))
      assert Links.satisfied?(ctx.bos1)

      bind!(ctx, :github)
      assert Links.waiting_for(ctx.bos1) == :merge
    end

    test "依赖 Epic", ctx do
      bind!(ctx, :github)
      epic = new_task(ctx, %{kind: "epic"})
      bos11 = new_task(ctx, %{epic: epic.ident})
      bos12 = new_task(ctx, %{epic: epic.ident})
      depends!(ctx, ctx.web2, epic)

      for {t, s} <- [{epic, :done}, {bos11, :verified}, {bos12, :cancelled}],
          do: put_status!(t, s)

      delivery!(ctx, bos11, :gh, sha("c"))
      delivery!(ctx, bos12, :gh, sha("e"))
      pr = pr!(ctx, bos11, :gh, :open, nil)
      put_status!(ctx.bos1, :done)

      assert link_waiting_for(ctx.web2, epic) == "steps"
      assert Links.blockers(ctx.web2.id) == [epic.ident]

      Repo.update_all(from(p in PullRequest, where: p.id == ^pr.id),
        set: [state: :merged, merged_at: DateTime.utc_now(), included_sha: sha("c")]
      )

      refute blocked?(ctx, ctx.web2)
    end
  end

  ## The reference model (decision 13)

  @statuses Task.statuses()
  @heads ["a", "b", "c"]

  defp subject_gen do
    fixed_map(%{
      status: member_of(@statuses),
      run: member_of([nil, :claimed, :running, :cancelling, :queued, :failed]),
      deliveries:
        list_of(
          fixed_map(%{
            target: member_of([:gh, :gh_other, :local, :local_other]),
            head: member_of(@heads),
            conflict: frequency([{4, constant(false)}, {1, constant(true)}]),
            offset: integer(0..2)
          }),
          max_length: 3
        ),
      prs:
        list_of(
          fixed_map(%{
            target: member_of([:gh, :gh_other]),
            state: member_of([:draft, :open, :merged, :closed]),
            included: member_of([nil | @heads])
          }),
          max_length: 2
        ),
      branch:
        one_of([
          constant(nil),
          fixed_map(%{
            target: member_of([:local, :local_other]),
            state: member_of(["open", "merged"]),
            head: member_of(@heads)
          })
        ])
    })
  end

  # Decision 2, written out.
  defp model_waiting_for(subject, binding, steps) do
    cond do
      subject.status not in [:done, :verified] -> :status
      subject.run in [:claimed, :running, :cancelling] -> :run
      not model_code?(subject, binding) -> :merge
      steps != nil and not Enum.all?(steps, &model_step?(&1, binding)) -> :steps
      true -> nil
    end
  end

  defp model_step?(%{status: :cancelled}, _binding), do: true
  defp model_step?(step, binding), do: model_waiting_for(step, binding, nil) == nil

  defp model_code?(_subject, :none), do: true

  defp model_code?(subject, binding) do
    current = if binding == :github, do: :gh, else: :local

    delivered =
      subject.deliveries
      |> Enum.with_index()
      |> Enum.filter(fn {d, _i} -> d.target == current and not d.conflict end)

    case Enum.max_by(delivered, fn {d, i} -> {d.offset, i} end, fn -> nil end) do
      nil ->
        true

      {latest, _i} when binding == :github ->
        case subject.prs |> Enum.filter(&(&1.target == :gh)) |> List.last() do
          %{state: :merged, included: head} -> head == latest.head
          _other -> false
        end

      {latest, _i} ->
        match?(%{target: :local, state: "merged"}, subject.branch) and
          subject.branch.head == latest.head
    end
  end

  defp as_string(nil), do: nil
  defp as_string(atom), do: Atom.to_string(atom)

  defp write_subject!(ctx, task, subject) do
    put_status!(task, subject.status)
    if subject.run, do: active_run!(ctx, task, subject.run)

    for d <- subject.deliveries,
        do: delivery!(ctx, task, d.target, sha(d.head), conflict: d.conflict, offset: d.offset)

    for p <- subject.prs, do: pr!(ctx, task, p.target, p.state, p.included && sha(p.included))

    if b = subject.branch, do: local_branch!(ctx, task, b.target, b.state, sha(b.head))
  end

  property "blocked, satisfied?, blockers and waiting_for equal the model", ctx do
    plain = new_task(ctx)
    epic = new_task(ctx, %{kind: "epic"})
    steps = [new_task(ctx, %{epic: epic.ident}), new_task(ctx, %{epic: epic.ident})]
    dependent = new_task(ctx)
    depends!(ctx, dependent, plain)
    depends!(ctx, dependent, epic)
    alone = new_task(ctx)
    depends!(ctx, alone, plain)
    subjects = [plain, epic | steps]
    ids = Enum.map(subjects, & &1.id)

    check all binding <- member_of([:none, :github, :local]),
              generated <- list_of(subject_gen(), length: 4),
              max_runs: 200 do
      Repo.delete_all(from(r in Run, where: r.task_id in ^ids))
      Repo.delete_all(from(p in PullRequest, where: p.task_id in ^ids))
      Repo.delete_all(from(b in TaskLocalBranch, where: b.task_id in ^ids))
      bind!(ctx, binding)
      Enum.zip(subjects, generated) |> Enum.each(fn {t, s} -> write_subject!(ctx, t, s) end)

      [s_plain, s_epic | s_steps] = generated
      expected_plain = model_waiting_for(s_plain, binding, nil)
      expected_epic = model_waiting_for(s_epic, binding, s_steps)

      assert Links.waiting_for(plain) == expected_plain
      assert Links.waiting_for(epic) == expected_epic
      assert Links.satisfied?(plain) == is_nil(expected_plain)

      expected_blockers =
        [{plain, expected_plain}, {epic, expected_epic}]
        |> Enum.reject(fn {_t, w} -> is_nil(w) end)
        |> Enum.sort_by(fn {t, _w} -> t.id end)
        |> Enum.map(fn {t, _w} -> t.ident end)

      assert Links.blockers(dependent.id) == expected_blockers

      assert link_waiting_for(dependent, plain) == as_string(expected_plain)

      assert link_waiting_for(dependent, epic) == as_string(expected_epic)

      expected_blocked = %{
        dependent.ident => expected_blockers != [],
        alone.ident => not is_nil(expected_plain)
      }

      {:ok, listed} = Tasks.list(ctx.alice_scope, ctx.project.key, limit: 200)

      assert listed
             |> Enum.filter(&Map.has_key?(expected_blocked, &1.ident))
             |> Map.new(&{&1.ident, &1.blocked}) == expected_blocked

      assert [dependent, alone]
             |> Enum.map(&Repo.reload!/1)
             |> Links.put_blocked()
             |> Map.new(&{&1.ident, &1.blocked}) == expected_blocked
    end
  end

  test "listing 50 tasks with 3 dependencies each: as many queries as without", ctx do
    bind!(ctx, :github)
    tasks = for _ <- 1..50, do: new_task(ctx)
    other = project_fixture(ctx.alice_scope, key: "PRQ")

    Repo.update_all(from(p in Project, where: p.id == ^other.id),
      set: [repository_id: ctx.repos.gh.id]
    )

    prereqs = for _ <- 1..3, do: task_fixture(ctx.alice_scope, other.key)

    {{:ok, plain}, without} =
      QueryCount.count(fn -> Tasks.list(ctx.alice_scope, ctx.project.key, limit: 50) end)

    assert length(plain) == 50

    for p <- prereqs do
      put_status!(p, :verified)
      delivery!(ctx, p, :gh, sha("c"))
      pr!(ctx, p, :gh, :open, nil)
    end

    Repo.insert_all(
      Link,
      for t <- tasks, p <- prereqs do
        %{
          workspace_id: ctx.workspace.id,
          from_task_id: t.id,
          to_task_id: p.id,
          type: :depends_on,
          actor_id: ctx.alice_scope.actor.id
        }
      end
    )

    {{:ok, linked}, with_links} =
      QueryCount.count(fn -> Tasks.list(ctx.alice_scope, ctx.project.key, limit: 50) end)

    assert Enum.all?(linked, & &1.blocked)
    assert with_links == without
  end
end

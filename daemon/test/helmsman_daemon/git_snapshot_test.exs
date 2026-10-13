defmodule HelmsmanDaemon.GitSnapshotTest do
  # add-autopilots 7.2: read-only checkouts of a GitHub-style repository (a
  # local bare repository serves as the remote).
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{GitWorkspace, Workspace}
  import HelmsmanDaemon.GitHelpers

  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)

  setup %{tmp_dir: dir} do
    start_execution()
    fixture = fixture(dir)
    cache = GitWorkspace.cache_path(fixture.url, 123_456_789, allow_file_urls: true)
    %{fixture: fixture, cache: cache, dir: dir}
  end

  defp snapshot_spec(fixture, id) do
    run = repo_spec(fixture, id)
    %{run | task: nil, repo: %{run.repo | mode: :snapshot, branch: nil, rescue_branches: []}}
  end

  defp task_spec(fixture, id, ident) do
    run = repo_spec(fixture, id)
    branch = "hm/1/" <> String.downcase(ident)
    limits = %{run.limits | timeout_ms: 120_000, idle_timeout_ms: 60_000}

    %{
      run
      | task: %{run.task | ident: ident},
        repo: %{run.repo | branch: branch},
        limits: limits
    }
  end

  defp start(run, instructions) do
    scenario = scenario!(Path.join(Paths.home(), "scenario-#{run.run_id}"), instructions)
    run = %{run | agent: %{run.agent | custom_args: [scenario]}}

    {:ok, _} =
      Runs.start_run(run,
        reporter: TestReporter,
        allow_file_urls: true,
        push_backoff_ms: [0, 0],
        kill_timeout_ms: 50
      )

    run
  end

  defp finished(id, status \\ :succeeded) do
    assert_receive {:report, ^id, %Report.Finished{status: ^status} = payload, _, _, _}, 15_000
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, id) == [] end)
    payload
  end

  defp refs(fixture, path),
    do: git!(fixture.git, path, ["for-each-ref", "--format=%(refname) %(objectname)"])

  defp heads(fixture, cache), do: git!(fixture.git, cache, ["for-each-ref", "refs/heads"])

  defp worktrees(fixture, cache) do
    fixture.git
    |> git!(cache, ["worktree", "list", "--porcelain"])
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.sort()
  end

  defp checkout(id), do: GitWorkspace.snapshot_path(Paths.run(id))

  test "run ends: no push, checkout and its registration removed, no new branch", ctx do
    %{fixture: fixture, cache: cache, dir: dir} = ctx
    remote_before = refs(fixture, fixture.remote)
    base = git!(fixture.git, fixture.seed, ["rev-parse", "HEAD"])
    out = Path.join(dir, "observed-41")

    start(snapshot_spec(fixture, 41), """
    sh pwd > #{out}
    write hello
    git_commit agent commit
    sh git symbolic-ref -q HEAD || echo detached >> #{out}
    sh git rev-parse HEAD^ >> #{out}
    #{@success}
    """)

    finished(41)
    refute_receive {:report, 41, %Report.Pushed{}, _, _, _}
    refute_receive {:report, 41, %Report.GitToken{}, _, _, _}

    assert [cwd, "detached", ^base] = String.split(File.read!(out), "\n", trim: true)
    assert Path.expand(cwd) == Path.expand(checkout(41))

    refute File.exists?(checkout(41))
    assert refs(fixture, fixture.remote) == remote_before
    assert heads(fixture, cache) == ""
    assert worktrees(fixture, cache) == [cache]
    refute File.exists?(Path.join(Paths.state(), "worktrees"))
  end

  test "failed and cancelled runs remove the checkout too", ctx do
    %{fixture: fixture, cache: cache} = ctx
    remote_before = refs(fixture, fixture.remote)

    start(snapshot_spec(fixture, 42), "write broken\ngit_commit broken\nexit 1\n")
    finished(42, :failed)
    refute File.exists?(checkout(42))

    barrier = Path.join(Paths.home(), "barrier-43")
    start(snapshot_spec(fixture, 43), "write stop\nbarrier #{barrier}\n" <> @success)
    eventually(fn -> File.exists?(barrier <> ".ready") end, 1_000)
    assert File.dir?(checkout(43))
    Runs.cancel(43)
    finished(43, :cancelled)

    refute_received {:report, _, %Report.Pushed{}, _, _, _}
    refute File.exists?(checkout(43))
    assert refs(fixture, fixture.remote) == remote_before
    assert heads(fixture, cache) == ""
    assert worktrees(fixture, cache) == [cache]
  end

  test "a checkout and a task worktree of the same repository run side by side", ctx do
    %{fixture: fixture, cache: cache} = ctx
    barrier = Path.join(Paths.home(), "task-barrier")
    task = task_spec(fixture, 50, "BOS-12")
    task_path = GitWorkspace.worktree_path(task)

    start(task, "write task\nbarrier #{barrier}\n" <> @success)
    eventually(fn -> File.exists?(barrier <> ".ready") end, 1_000)

    start(snapshot_spec(fixture, 51), "write snapshot\ngit_commit snapshot\n" <> @success)
    finished(51)
    refute File.exists?(checkout(51))

    assert File.read!(Path.join(task_path, "hello.txt")) == "task\n"
    assert git!(fixture.git, task_path, ["symbolic-ref", "HEAD"]) == "refs/heads/hm/1/bos-12"
    assert worktrees(fixture, cache) == Enum.sort([cache, task_path])

    File.write!(barrier <> ".release", "go")
    assert_receive {:report, 50, %Report.Pushed{branch: "hm/1/bos-12"}, _, _, _}, 15_000
    finished(50)

    assert git!(fixture.git, fixture.remote, ["show", "hm/1/bos-12:hello.txt"]) == "task"
    assert heads(fixture, cache) =~ "refs/heads/hm/1/bos-12"
    refute heads(fixture, cache) =~ "snapshot"
    assert worktrees(fixture, cache) == Enum.sort([cache, task_path])
  end

  test "after a crash the next preparation prunes the leftover checkout", ctx do
    %{fixture: fixture, cache: cache} = ctx
    task = task_spec(fixture, 59, "BOS-1")
    assert {:ok, %GitWorkspace{snapshot?: false}} = prepare(task)
    task_path = GitWorkspace.worktree_path(task)

    assert {:ok, %GitWorkspace{snapshot?: true, path: crashed}} =
             prepare(snapshot_spec(fixture, 60))

    assert File.dir?(crashed)
    assert worktrees(fixture, cache) == Enum.sort([cache, task_path, crashed])

    # What crash recovery does with the run directory of an unfinished run.
    Workspace.cleanup(60)
    refute File.exists?(crashed)

    assert {:ok, %GitWorkspace{snapshot?: true, path: fresh} = workspace} =
             prepare(snapshot_spec(fixture, 61))

    assert File.read!(Path.join(fresh, "base.txt")) == "base\n"
    assert worktrees(fixture, cache) == Enum.sort([cache, task_path, fresh])

    assert :ok = GitWorkspace.discard(workspace)
    assert :ok = GitWorkspace.discard(workspace)
    refute File.exists?(fresh)
    assert worktrees(fixture, cache) == Enum.sort([cache, task_path])
    assert git!(fixture.git, task_path, ["symbolic-ref", "HEAD"]) == "refs/heads/hm/1/bos-1"
  end

  test "a missing base branch fails preparation without a checkout", ctx do
    run = snapshot_spec(ctx.fixture, 62)
    run = %{run | repo: %{run.repo | base_branch: "nope"}}

    assert {:error, {:workspace_prepare, "base branch nope not found on the remote"}} =
             prepare(run)

    refute File.exists?(checkout(62))
  end
end

defmodule HelmsmanDaemon.LocalGitSnapshotTest do
  # add-autopilots 7.2: a read-only checkout of a local repository leaves the
  # user's repository exactly as it was.
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import HelmsmanDaemon.LocalRepoHelpers
  alias HelmsmanDaemon.{GitWorkspace, LocalRepos}

  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)

  setup %{tmp_dir: tmp_dir} do
    isolate_home(tmp_dir)
    start_execution()
    user = user_repo()
    configure([{"app", user, [1]}])
    %{user: user}
  end

  test "the run commits in the checkout; nothing reaches the user's repository", %{user: user} do
    before = snapshot(user)
    repo = %{local_repo(nil) | mode: :snapshot}
    run = %{spec(70) | task: nil, repo: repo}

    scenario =
      scenario!(Path.join(Paths.home(), "scenario-70"), """
      write hello
      git_commit agent commit
      #{@success}
      """)

    {:ok, _} =
      Runs.start_run(%{run | agent: %{run.agent | custom_args: [scenario]}},
        reporter: TestReporter,
        kill_timeout_ms: 50
      )

    assert_receive {:report, 70, %Report.Finished{status: :succeeded}, _, _, _}, 20_000
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, 70) == [] end)
    refute_received {:report, 70, %Report.Pushed{}, _, _, _}

    assert snapshot(user) == before
    assert git!(user, ["for-each-ref", "refs/heads/hm"]) == ""

    cache = LocalRepos.cache_path("app")
    assert git!(cache, ["for-each-ref", "refs/heads"]) == ""
    assert git!(cache, ["worktree", "list", "--porcelain"]) =~ ~r/\Aworktree [^\n]+\nbare\z/
    refute File.exists?(GitWorkspace.snapshot_path(Paths.run(70)))
  end
end

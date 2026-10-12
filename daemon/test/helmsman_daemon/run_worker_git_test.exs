defmodule HelmsmanDaemon.RunWorkerGitTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{GitLedger, GitWorkspace}
  import HelmsmanDaemon.GitHelpers

  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)

  setup %{tmp_dir: dir} do
    start_execution()
    %{fixture: fixture(dir)}
  end

  defp start(fixture, id, instructions, opts \\ []) do
    run = repo_spec(fixture, id)
    scenario = scenario!(Path.join(Paths.home(), "scenario-#{id}"), instructions)
    run = %{run | agent: %{run.agent | custom_args: [scenario]}}

    opts =
      Keyword.merge(
        [
          reporter: TestReporter,
          allow_file_urls: true,
          push_backoff_ms: [0, 0],
          kill_timeout_ms: 50
        ],
        opts
      )

    {:ok, worker} = Runs.start_run(run, opts)
    {worker, run}
  end

  defp finished(id, status \\ :succeeded) do
    assert_receive {:report, ^id, %Report.Finished{status: ^status} = payload, _, _, _}, 15_000
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, id) == [] end)
    payload
  end

  defp pushed(id) do
    assert_receive {:report, ^id, %Report.Pushed{} = payload, _, _, _}, 15_000
    payload
  end

  defp hook(fixture, name, contents) do
    path = Path.join([fixture.remote, "hooks", name])
    File.write!(path, "#!/bin/sh\n" <> contents)
    File.chmod!(path, 0o700)
  end

  defp remote_head(fixture, target \\ "hm/1/bos-1"),
    do: git!(fixture.git, fixture.remote, ["rev-parse", "refs/heads/" <> target])

  test "auto commit then pushed acknowledgement then finished; clean ledger", %{fixture: fixture} do
    base = git!(fixture.git, fixture.seed, ["rev-parse", "HEAD"])
    {_, run} = start(fixture, 40, "write hello\n" <> @success)
    report = pushed(40)
    assert report.base_sha == base
    assert report.head_sha == remote_head(fixture)
    assert [%{subject: "BOS-1: uncommitted changes from run 40"}] = report.commits

    assert git!(fixture.git, fixture.remote, [
             "show",
             "--format=%an <%ae>",
             "--no-patch",
             report.head_sha
           ]) == "Fake <Fake@agents.localhost>"

    finished(40)
    refute File.exists?(GitLedger.path(run))
  end

  test "no changes skips push and preserves remote commit count", %{fixture: fixture} do
    {_, run} = start(fixture, 40, @success)
    finished(40)
    refute_receive {:report, 40, %Report.Pushed{}, _, _, _}
    refute File.exists?(GitLedger.path(run))
    assert git!(fixture.git, fixture.remote, ["rev-list", "--count", "main"]) == "1"
  end

  test "Agent commits are pushed and remote base is captured before CLI", %{fixture: fixture} do
    push(fixture, "main", "hm/1/bos-1")
    base = remote_head(fixture)
    start(fixture, 40, "write hello\ngit_commit agent commit\n" <> @success)
    report = pushed(40)
    assert report.base_sha == base
    assert [%{subject: "agent commit"}] = report.commits
    finished(40)
  end

  test "CLI failure preserves original conclusion after push", %{fixture: fixture} do
    start(fixture, 40, "write hello\ngit_commit before failure\nerr failed\nexit 7\n")
    pushed(40)
    assert %{failure_reason: :cli_error, error: error} = finished(40, :failed)
    assert error =~ "7"
  end

  test "cancel, timeout and stalled runs still commit and push", %{fixture: fixture} do
    for {id, reason, options} <- [
          {40, :cancel, []},
          {41, :timeout, [timeout_ms: 200]},
          {42, :stalled, [idle_timeout_ms: 200]}
        ] do
      run = repo_spec(fixture, id)

      scenario =
        scenario!(Path.join(Paths.home(), "stop-#{id}"), "write hello #{id}\nsleep 600\n")

      run = %{
        run
        | agent: %{run.agent | custom_args: [scenario]},
          limits: struct!(run.limits, options)
      }

      {:ok, _} =
        Runs.start_run(run, reporter: TestReporter, allow_file_urls: true, kill_timeout_ms: 50)

      assert_receive {:report, ^id, %Report.Started{}, _, _, _}, 10_000

      eventually(fn ->
        File.read(Path.join(GitWorkspace.worktree_path(run), "hello.txt")) ==
          {:ok, "hello #{id}\n"}
      end)

      if reason == :cancel, do: Runs.cancel(id)
      pushed(id)
      result = finished(id, if(reason == :cancel, do: :cancelled, else: :failed))
      if reason != :cancel, do: assert(result.failure_reason == reason)
    end
  end

  test "remote advance falls back to rescue and fails with push_conflict", %{fixture: fixture} do
    push(fixture, "main", "hm/1/bos-1")
    barrier = Path.join(Paths.home(), "cli-barrier")

    {_, run} =
      start(fixture, 40, "write local\nbarrier #{barrier}\n" <> @success,
        push_args: ["--receive-pack=" <> receive_pack(fixture)]
      )

    eventually(fn -> File.exists?(barrier <> ".ready") end, 1_000)
    commit(fixture.git, fixture.seed, "other.txt", "other", "remote change")
    push(fixture, "main", run.repo.branch)
    File.write!(barrier <> ".release", "go")
    report = pushed(40)
    assert report.rescue_branch == "hm/1/bos-1-run-40"
    assert remote_head(fixture, report.rescue_branch) == report.head_sha
    assert %{failure_reason: :push_conflict} = finished(40, :failed)
  end

  test "three network failures retain commits and inheritance and next run reports both", %{
    fixture: fixture
  } do
    hook(fixture, "pre-receive", "echo 'Could not resolve host' >&2\nexit 1\n")
    opts = [push_args: ["--receive-pack=" <> receive_pack(fixture)]]
    {_, run} = start(fixture, 40, "write first\n" <> @success, opts)
    assert %{failure_reason: :push_failed} = finished(40, :failed)
    assert GitLedger.read(run)["inherit"] == [40]
    refute_receive {:report, 40, %Report.Pushed{}, _, _, _}
    assert_receive {:report, 40, %Report.GitToken{}, _, _, _}
    File.rm!(Path.join([fixture.remote, "hooks", "pre-receive"]))
    start(fixture, 41, @success, opts)
    current = pushed(41)
    inherited = pushed(40)
    assert %{current | run_id: 40} == inherited
    assert [%{subject: "BOS-1: uncommitted changes from run 40"}] = current.commits
    finished(41)
    refute File.exists?(GitLedger.path(run))
  end

  test "new and inherited commits are reported together", %{fixture: fixture} do
    hook(fixture, "pre-receive", "echo 'Could not resolve host' >&2\nexit 1\n")
    opts = [push_args: ["--receive-pack=" <> receive_pack(fixture)]]
    start(fixture, 40, "write first\n" <> @success, opts)
    finished(40, :failed)
    File.rm!(Path.join([fixture.remote, "hooks", "pre-receive"]))
    start(fixture, 41, "write second\n" <> @success, opts)
    report = pushed(41)
    assert length(report.commits) == 2
    assert %{report | run_id: 40} == pushed(40)
    finished(41)
  end

  test "authentication rejection renews then succeeds", %{fixture: fixture} do
    marker = Path.join(Paths.home(), "auth-once")

    hook(
      fixture,
      "pre-receive",
      "if [ ! -f '#{marker}' ]; then touch '#{marker}'; echo 'Authentication failed' >&2; exit 1; fi\n"
    )

    start(fixture, 40, "write hello\n" <> @success,
      push_args: ["--receive-pack=" <> receive_pack(fixture)]
    )

    assert_receive {:report, 40, %Report.GitToken{}, _, _, _}, 6_000
    pushed(40)
    finished(40)
  end

  test "expiring token is renewed before pushing; wrong_state consumes an attempt", %{
    fixture: fixture
  } do
    TestReporter.configure(fn
      %Report.GitToken{} ->
        {:error,
         %HelmsmanProtocol.ErrorReply{reason: :wrong_state, message: "GitHub unavailable"}}

      payload ->
        TestReporter.default(payload)
    end)

    start(fixture, 40, "write hello\n" <> @success, token_expires_at: DateTime.utc_now())
    for _ <- 1..3, do: assert_receive({:report, 40, %Report.GitToken{}, _, _, _}, 6_000)
    assert %{failure_reason: :push_failed} = finished(40, :failed)
    refute_receive {:report, 40, %Report.Pushed{}, _, _, _}
    TestReporter.configure(&TestReporter.default/1)
    start(fixture, 41, @success, token_expires_at: DateTime.utc_now())
    assert_receive {:report, 41, %Report.GitToken{}, _, _, _}, 6_000
    pushed(41)
    pushed(40)
    finished(41)
  end

  test "pushed retries identical payload while disconnected and finished waits for reply", %{
    fixture: fixture
  } do
    TestReporter.configure(fn
      %Report.Pushed{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {worker, run} = start(fixture, 40, "write hello\n" <> @success, report_resubmit_ms: 100)
    assert_receive {:report, 40, %Report.Pushed{} = first, ^worker, first_ref, _}, 6_000
    ledger = GitLedger.read(run)
    assert [%{"runs" => [%{"acked" => false}]}] = ledger["outbox"]
    assert_receive {:report, 40, %Report.Pushed{} = retry, ^worker, _ref, _}, 1_000
    assert retry == first
    refute_receive {:report, 40, %Report.Finished{}, _, _, _}, 30
    send(worker, {:report_result, first_ref, {:ok, %Reply.Empty{}}})
    finished(40)
  end

  test "push landed before missing transport confirmation is recognized", %{fixture: fixture} do
    hook(fixture, "post-receive", "sleep 3\n")

    start(fixture, 40, "write hello\n" <> @success,
      push_args: ["--receive-pack=" <> receive_pack(fixture)],
      command_timeout_ms: 1_000
    )

    report = pushed(40)
    assert report.head_sha == remote_head(fixture)
    finished(40)
    refute_receive {:report, 40, %Report.GitToken{}, _, _, _}
  end

  test "finalization deadline fails and leaves ledger intact", %{fixture: fixture} do
    hook(fixture, "pre-receive", "sleep 10\nexit 1\n")

    {_, run} =
      start(fixture, 40, "write hello\n" <> @success,
        push_args: ["--receive-pack=" <> receive_pack(fixture)],
        finalize_timeout_ms: 1_000
      )

    assert %{failure_reason: :push_failed} = finished(40, :failed)
    assert GitLedger.read(run)["inherit"] == [40]
  end

  test "crash at unacknowledged pushed barrier replays exact payload without new commits", %{
    fixture: fixture
  } do
    TestReporter.configure(fn
      %Report.Pushed{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {worker, run} = start(fixture, 40, "write hello\n" <> @success)
    assert_receive {:report, 40, %Report.Pushed{} = original, ^worker, _, _}, 6_000
    assert remote_head(fixture) == original.head_sha
    assert GitLedger.read(run)["outbox"] != []
    Process.exit(worker, :kill)
    eventually(fn -> not Process.alive?(worker) and Runs.active() == [] end)
    TestReporter.configure(&TestReporter.default/1)
    start(fixture, 41, @success)
    assert pushed(40) == original
    finished(41)
    assert remote_head(fixture) == original.head_sha
    refute_receive {:report, 41, %Report.Pushed{}, _, _, _}
    refute File.exists?(GitLedger.path(run))
  end

  test "crash at inherited report only replays unacknowledged inherited run", %{fixture: fixture} do
    hook(fixture, "pre-receive", "echo 'Could not resolve host' >&2\nexit 1\n")
    opts = [push_args: ["--receive-pack=" <> receive_pack(fixture)]]
    {_, run} = start(fixture, 40, "write first\n" <> @success, opts)
    finished(40, :failed)
    File.rm!(Path.join([fixture.remote, "hooks", "pre-receive"]))

    TestReporter.configure(fn
      %Report.Pushed{run_id: 40} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {worker, _} = start(fixture, 41, @success, opts)
    pushed(41)
    assert_receive {:report, 40, %Report.Pushed{} = original, ^worker, _, _}, 6_000

    assert [
             %{
               "runs" => [%{"run_id" => 41, "acked" => true}, %{"run_id" => 40, "acked" => false}]
             }
           ] = GitLedger.read(run)["outbox"]

    Process.exit(worker, :kill)
    eventually(fn -> not Process.alive?(worker) and Runs.active() == [] end)
    TestReporter.configure(&TestReporter.default/1)
    start(fixture, 42, @success, opts)
    assert pushed(40) == original
    finished(42)
    refute_receive {:report, 41, %Report.Pushed{}, _, _, _}
    refute_receive {:report, 42, %Report.Pushed{}, _, _, _}
    assert remote_head(fixture) == original.head_sha
    refute File.exists?(GitLedger.path(run))
  end

  test "inherited pushed wrong_state is acknowledged with warning", %{fixture: fixture} do
    hook(fixture, "pre-receive", "echo 'Could not resolve host' >&2\nexit 1\n")
    opts = [push_args: ["--receive-pack=" <> receive_pack(fixture)]]
    {_, run} = start(fixture, 40, "write first\n" <> @success, opts)
    finished(40, :failed)
    File.rm!(Path.join([fixture.remote, "hooks", "pre-receive"]))

    TestReporter.configure(fn
      %Report.Pushed{run_id: 40} ->
        {:error, %HelmsmanProtocol.ErrorReply{reason: :wrong_state, message: "already recorded"}}

      payload ->
        TestReporter.default(payload)
    end)

    start(fixture, 41, @success, opts)
    pushed(41)
    pushed(40)
    finished(41)
    assert_receive {:report, 41, %Report.Events{events: events}, _, _, _}
    assert Enum.any?(events, &(&1.type == :status and &1.data.message =~ "run 40"))
    refute File.exists?(GitLedger.path(run))
  end

  test "push intention exists before push and next run waits for old finalization", %{
    fixture: fixture
  } do
    gate = Path.join(Paths.home(), "push-gate")

    hook(
      fixture,
      "pre-receive",
      "touch '#{gate}.ready'\nwhile [ ! -f '#{gate}.release' ]; do sleep 0.01; done\n"
    )

    opts = [push_args: ["--receive-pack=" <> receive_pack(fixture)]]
    {worker, run} = start(fixture, 40, "write hello\n" <> @success, opts)
    eventually(fn -> File.exists?(gate <> ".ready") end, 600)
    assert [%{"head_sha" => head, "runs" => [%{"run_id" => 40}]}] = GitLedger.read(run)["outbox"]
    assert head == git!(fixture.git, GitWorkspace.worktree_path(run), ["rev-parse", "HEAD"])
    {next, _} = start(fixture, 41, @success, opts)
    refute_receive {:report, 41, %Report.Starting{}, _, _, _}, 100
    assert Process.alive?(worker) and Process.alive?(next)
    File.write!(gate <> ".release", "go")
    pushed(40)
    finished(40)
    finished(41)
    refute_receive {:report, 41, %Report.Pushed{}, _, _, _}
  end

  test "unresolved merge retains conflicts, warns and only pushes existing commits", %{
    fixture: fixture
  } do
    run = repo_spec(fixture, 40)
    push(fixture, "main", run.repo.branch)
    assert {:ok, workspace} = prepare(run)
    local = commit(workspace.git, workspace.path, "base.txt", "local", "local change")
    remote = commit(fixture.git, fixture.seed, "base.txt", "remote", "remote change")
    push(fixture, "HEAD", run.repo.branch <> "-run-39")
    assert remote != local
    git!(workspace.git, workspace.path, ["fetch", "origin"])

    assert {:error, _} =
             HelmsmanDaemon.Git.run(
               ["merge", "--no-edit", "refs/remotes/origin/" <> run.repo.branch <> "-run-39"],
               workspace.path,
               workspace.git
             )

    commit_count = git!(workspace.git, workspace.path, ["rev-list", "--count", "HEAD"])
    {_, next_run} = start(fixture, 41, @success)
    assert pushed(41).head_sha == local
    finished(41)
    assert git!(workspace.git, workspace.path, ["rev-list", "--count", "HEAD"]) == commit_count

    assert git!(workspace.git, workspace.path, ["diff", "--name-only", "--diff-filter=U"]) ==
             "base.txt"

    assert GitLedger.read(next_run)["inherit"] == [41]
    assert_receive {:report, 41, %Report.Events{events: events}, _, _, _}

    assert Enum.any?(
             events,
             &(&1.type == :status and &1.data.message =~ "unresolved merge conflicts")
           )
  end

  test "unlanded outbox becomes inheritance and is reported after a later push", %{
    fixture: fixture
  } do
    run = repo_spec(fixture, 40)
    assert {:ok, workspace} = prepare(run)
    base = workspace.remote_base
    head = commit(workspace.git, workspace.path, "hello.txt", "pending", "pending commit")

    entry = %{
      "target" => run.repo.branch,
      "branch" => run.repo.branch,
      "base_sha" => base,
      "head_sha" => head,
      "rescue_branch" => nil,
      "commits" => [%{"sha" => head, "subject" => "pending commit"}],
      "runs" => [%{"run_id" => 40, "acked" => false}]
    }

    GitLedger.write(run, %{"inherit" => [], "outbox" => [entry]})

    TestReporter.configure(fn
      %Report.Starting{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {worker, _} = start(fixture, 41, @success)
    assert_receive {:report, 41, %Report.Starting{}, ^worker, ref, _}, 6_000
    assert %{"inherit" => [40, 41], "outbox" => []} = GitLedger.read(run)
    assert Bitwise.band(File.stat!(GitLedger.path(run)).mode, 0o777) == 0o600
    send(worker, {:report_result, ref, {:ok, %Reply.Starting{action: :proceed}}})
    report = pushed(41)
    assert report.head_sha == head
    assert %{report | run_id: 40} == pushed(40)
    finished(41)
  end

  test "commit list is latest 250 and subjects respect byte limit", %{fixture: fixture} do
    run = repo_spec(fixture, 40)
    assert {:ok, workspace} = prepare(run)
    # Plumbing builds a real 251-commit chain quickly, with no repeated filesystem changes.
    tree = git!(workspace.git, workspace.path, ["rev-parse", "HEAD^{tree}"])
    long_subject = String.duplicate("界", 400)

    head =
      Enum.reduce(1..251, workspace.remote_base, fn n, parent ->
        git!(workspace.git, workspace.path, [
          "commit-tree",
          tree,
          "-p",
          parent,
          "-m",
          if(n == 251, do: long_subject, else: "commit #{n}")
        ])
      end)

    git!(workspace.git, workspace.path, ["reset", "--hard", head])
    start(fixture, 40, @success)
    report = pushed(40)
    assert length(report.commits) == 250
    assert hd(report.commits).sha == head
    assert byte_size(hd(report.commits).subject) <= 1024
    assert String.valid?(hd(report.commits).subject)
    assert List.last(report.commits).subject == "commit 2"
    finished(40)
    assert_receive {:report, 40, %Report.Events{events: events}, _, _, _}
    assert Enum.any?(events, &(&1.type == :status and &1.data.message =~ "latest 250"))
  end

  test "Agent pre-push hook and credential helpers never run during finalization", %{
    fixture: fixture
  } do
    helper_marker = Path.join(Paths.home(), "helper-called")
    hook_marker = Path.join(Paths.home(), "hook-called")
    helper = Path.join(Paths.home(), "credential-helper")
    File.write!(helper, "#!/bin/sh\necho called >> '#{helper_marker}'\n")
    File.chmod!(helper, 0o700)
    home = Path.join(Paths.home(), "cli-home")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, ".gitconfig"),
      "[credential]\n helper = #{helper}\n[credential \"https://github.com\"]\n helper = #{helper}\n"
    )

    stored = Path.join(home, ".git-credentials")
    File.write!(stored, "https://user:original@github.com\n")
    before = File.stat!(stored)

    {_, run} =
      start(fixture, 40, "write safe\n" <> @success,
        base_env: Map.put(System.get_env(), "HOME", home)
      )

    report = pushed(40)
    finished(40)

    cache =
      GitWorkspace.cache_path(run.repo.clone_url, run.repo.github_repository_id,
        allow_file_urls: true
      )

    hook = Path.join(cache, "hooks/pre-push")
    File.write!(hook, "#!/bin/sh\nenv > '#{hook_marker}'\n")
    File.chmod!(hook, 0o700)
    git!(fixture.git, cache, ["config", "credential.helper", helper])
    git!(fixture.git, cache, ["config", "credential.https://github.com.helper", helper])

    start(fixture, 41, "write safer\n" <> @success,
      base_env: Map.put(System.get_env(), "HOME", home)
    )

    assert pushed(41).base_sha == report.head_sha
    finished(41)
    refute File.exists?(hook_marker)
    refute File.exists?(helper_marker)
    assert File.read!(stored) == "https://user:original@github.com\n"
    assert File.stat!(stored).mtime == before.mtime

    for file <- Path.wildcard(Path.join(Paths.home(), "**/*"), match_dot: true),
        File.regular?(file) do
      refute File.read!(file) =~ run.repo.git_token, "token leaked into #{file}"
      refute File.read!(file) =~ "ghs_RENEWED_TOKEN", "renewed token leaked into #{file}"
    end
  end

  test "worker crash pins worktree until delayed CLI cleanup empties old group", %{
    fixture: fixture
  } do
    owner = self()

    {worker, run} =
      start(fixture, 40, "ignore_term\nspawn_child\nsleep 600\n",
        before_cli_cleanup: fn ->
          send(owner, {:cleanup_barrier, self()})

          receive do
            :continue -> :ok
          end
        end
      )

    assert_receive {:report, 40, %Report.Started{}, _, _, _}, 10_000
    state = :sys.get_state(worker)
    registry_owner = Process.whereis(Runs)
    true = :erlang.suspend_process(registry_owner)

    try do
      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert_receive {:cleanup_barrier, guardian}, 2_000

      spawn(fn ->
        HelmsmanDaemon.RepoCache.with_worktree_lock(GitWorkspace.worktree_path(run), fn ->
          send(owner, {:next_entered, HelmsmanDaemon.ProcGroup.live_snapshot(state.pgid)})
        end)
      end)

      refute_receive {:next_entered, _}, 100
      assert {:ok, [_ | _]} = HelmsmanDaemon.ProcGroup.live_snapshot(state.pgid)
      send(guardian, :continue)
      assert_receive {:next_entered, {:ok, []}}, 6_000
    after
      if Process.alive?(state.cli_guardian), do: send(state.cli_guardian, :continue)
      if Process.alive?(registry_owner), do: :erlang.resume_process(registry_owner)
      HelmsmanDaemon.Exec.signal_group(state.pgid, 9)
    end
  end
end

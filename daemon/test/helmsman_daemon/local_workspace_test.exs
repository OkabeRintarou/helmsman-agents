defmodule HelmsmanDaemon.LocalWorkspaceTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import HelmsmanDaemon.LocalRepoHelpers
  alias HelmsmanDaemon.{GitLedger, GitWorkspace, LocalRepos, RepoCache}

  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)
  @branch "hm/1/bos-1"

  setup %{tmp_dir: tmp_dir} do
    isolate_home(tmp_dir)
    start_execution()
    root = scratch()
    user = user_repo(root)
    configure([{"app", user, [1]}])
    %{root: root, user: user}
  end

  defp start(id, instructions, opts \\ []) do
    run = %{spec(id) | repo: local_repo(@branch, Keyword.get(opts, :rescues, []))}
    scenario = scenario!(Path.join(Paths.home(), "scenario-#{id}"), instructions)
    run = %{run | agent: %{run.agent | custom_args: [scenario]}}

    {:ok, _} =
      Runs.start_run(
        run,
        Keyword.merge(
          [reporter: TestReporter, push_backoff_ms: [0, 0], kill_timeout_ms: 50],
          Keyword.delete(opts, :rescues)
        )
      )

    run
  end

  defp finished(id, status \\ :succeeded) do
    assert_receive {:report, ^id, %Report.Finished{status: ^status} = payload, _, _, _}, 20_000
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, id) == [] end)
    payload
  end

  defp pushed(id) do
    assert_receive {:report, ^id, %Report.Pushed{} = payload, _, _, _}, 20_000
    payload
  end

  defp ref(user, branch),
    do: git(user, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])

  test "delivers the task branch without touching the user's checkout", %{user: user} do
    before = snapshot(user)
    run = start(40, "write hello\ngit_commit agent commit\nwrite more\n" <> @success)
    report = pushed(40)
    assert %{branch: @branch, rescue_branch: nil} = report

    assert [%{subject: "BOS-1: uncommitted changes from run 40"}, %{subject: "agent commit"}] =
             report.commits

    assert ref(user, @branch) == {:ok, report.head_sha <> "\n"}
    assert finished(40).status == :succeeded
    assert snapshot(user) == before
    refute_received {:report, 40, %Report.GitToken{}, _, _, _}
    refute File.exists?(GitLedger.path(run))

    cache = LocalRepos.cache_path("app")
    assert git!(cache, ["rev-parse", "--is-bare-repository"]) == "true"
    assert git!(cache, ["remote", "get-url", "origin"]) == user
    assert String.starts_with?(GitWorkspace.worktree_path(run), Paths.home())
    refute File.exists?(Path.join([user, ".git", "worktrees"]))
  end

  test "the user's hooks never run", %{root: root, user: user} do
    for hook <- ~w(pre-receive update post-receive post-update reference-transaction) do
      path = Path.join([user, ".git", "hooks", hook])
      File.write!(path, "#!/bin/sh\ntouch '#{Path.join(root, hook <> ".ran")}'\n")
      File.chmod!(path, 0o755)
    end

    start(40, "write hello\n" <> @success)
    pushed(40)
    finished(40)
    assert ref(user, @branch) |> elem(0) == :ok
    assert Path.wildcard(Path.join(root, "*.ran")) == []
  end

  test "commands give the user's side refuse and no hooks on its own command line", %{
    root: root
  } do
    log = Path.join(root, "argv.log")
    wrapper = Path.join(root, "git-wrapper")

    File.write!(
      wrapper,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '#{log}'\nexec '#{System.find_executable("git")}' \"$@\"\n"
    )

    File.chmod!(wrapper, 0o755)
    start(40, "write hello\n" <> @success, executable: wrapper)
    pushed(40)
    finished(40)
    lines = String.split(File.read!(log), "\n", trim: true)

    assert Enum.any?(lines, fn line ->
             line =~
               "push --receive-pack='#{wrapper}' -c receive.denyCurrentBranch=refuse -c core.hooksPath=/dev/null receive-pack"
           end)

    assert Enum.any?(
             lines,
             &(&1 =~ "fetch --upload-pack='#{wrapper}' -c core.hooksPath=/dev/null upload-pack")
           )

    assert Enum.any?(
             lines,
             &(&1 =~
                 ~r/^-c receive.denyCurrentBranch=refuse -c core.hooksPath=\/dev\/null receive-pack /)
           )

    refute Enum.any?(lines, &(&1 =~ "askpass"))
  end

  for {setting, where} <- [
        {nil, :main},
        {"updateInstead", :main},
        {"ignore", :main},
        {nil, :linked},
        {"updateInstead", :linked},
        {"ignore", :linked}
      ] do
    @tag setting: setting, where: where
    test "a checked-out task branch (#{setting || "default"}, #{where} worktree) gets a rescue branch",
         %{root: root, user: user, setting: setting, where: where} do
      start(40, "write first\n" <> @success)
      first = pushed(40)
      finished(40)

      if setting, do: git!(user, ["config", "receive.denyCurrentBranch", setting])
      review = Path.join(root, "review")

      checkout =
        case where do
          :main ->
            git!(user, ["switch", "-q", @branch])
            user

          :linked ->
            git!(user, ["worktree", "add", "-q", review, @branch])
            review
        end

      File.write!(Path.join(checkout, "notes.txt"), "user notes\n")
      git!(checkout, ["add", "notes.txt"])
      before = {snapshot(user), snapshot(checkout)}

      start(41, "write second\n" <> @success)
      report = pushed(41)
      assert report.rescue_branch == @branch <> "-run-41"
      assert ref(user, @branch) == {:ok, first.head_sha <> "\n"}
      assert ref(user, report.rescue_branch) == {:ok, report.head_sha <> "\n"}
      result = finished(41, :failed)
      assert result.failure_reason == :push_conflict

      assert result.error =~
               "\nThe task branch #{@branch} is checked out in app; check out another branch there so the next delivery can update it."

      assert {snapshot(user), snapshot(checkout)} == before
    end
  end

  test "revoked sharing during the run: no delivery, push_failed, commits kept for the next run",
       %{user: user} do
    barrier = Path.join(Paths.home(), "cli-barrier")
    before = snapshot(user)
    run = start(40, "write hello\nbarrier #{barrier}\n" <> @success)
    eventually(fn -> File.exists?(barrier <> ".ready") end, 1_000)
    configure([{"app", user, [2]}])
    File.write!(barrier <> ".release", "go")

    result = finished(40, :failed)
    assert result.failure_reason == :push_failed

    assert result.error =~
             "local repository app is not shared with this workspace on this machine"

    assert result.error =~ "not delivered"
    refute_received {:report, 40, %Report.Pushed{}, _, _, _}
    assert ref(user, @branch) |> elem(0) == :error
    assert snapshot(user) == before
    assert GitLedger.read(run)["inherit"] == [40]

    configure([{"app", user, [1]}])
    start(41, @success)
    current = pushed(41)
    assert %{current | run_id: 40} == pushed(40)
    assert [%{subject: "BOS-1: uncommitted changes from run 40"}] = current.commits
    finished(41)
    refute File.exists?(GitLedger.path(run))
  end

  # Holds a repository cache lock in another process until `:release`.
  defp hold_lock(cache) do
    test = self()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(cache, fn ->
          send(test, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked
    holder
  end

  defp reported(id) do
    receive do
      {:report, ^id, %Report.Finished{} = payload, _, _, _} -> [payload]
      {:report, ^id, payload, _, _, _} -> [payload | reported(id)]
    after
      20_000 -> flunk("run #{id} did not finish")
    end
  end

  test "sharing revoked while waiting for the cache lock: no access to the user's repository",
       %{user: user} do
    before = snapshot(user)
    cache = LocalRepos.cache_path("app")
    holder = hold_lock(cache)
    start(40, "write hello\n" <> @success)
    eventually(fn -> File.dir?(Paths.run(40)) end)
    Process.sleep(200)
    configure([{"app", user, [2]}])
    send(holder, :release)

    assert %{failure_reason: :workspace_prepare, error: error} = finished(40, :failed)
    assert error =~ "not shared with this workspace on this machine"
    refute File.exists?(cache)
    assert snapshot(user) == before
  end

  test "sharing revoked after the lock but before the first fetch: no fetch, no worktree",
       %{root: root, user: user} do
    cache = seed_cache(user)
    git = pausing_git(root, "remote get-url origin")
    before = snapshot(user)
    run = start(40, "write hello\n" <> @success, executable: git.executable)
    eventually(fn -> File.exists?(git.ready) end, 1_000)
    configure([{"app", user, [2]}])
    File.write!(git.log, "")
    File.write!(git.release, "go")

    assert %{failure_reason: :workspace_prepare, error: error} = finished(40, :failed)
    assert error =~ "not shared with this workspace on this machine"
    refute user_repo_access?(git.log)
    refute File.exists?(Path.join(cache, "FETCH_HEAD"))
    refute File.exists?(GitWorkspace.worktree_path(run))
    assert snapshot(user) == before
  end

  test "sharing revoked between push attempts: no further access, commits kept, path redacted",
       %{root: root, user: user} do
    log = Path.join(root, "argv.log")
    ready = Path.join(root, "push.ready")
    release = Path.join(root, "push.release")
    wrapper = Path.join(root, "git-wrapper")
    git = System.find_executable("git")

    File.write!(wrapper, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{log}'
    case " $* " in
      *" push "*)
        if [ ! -f '#{ready}' ]; then
          touch '#{ready}'
          while [ ! -f '#{release}' ]; do sleep 0.01; done
          echo "fatal: unable to access '#{user}': Could not resolve host" >&2
          echo "error: failed to push some refs to '#{user}'" >&2
          exit 1
        fi ;;
    esac
    exec '#{git}' "$@"
    """)

    File.chmod!(wrapper, 0o755)
    before = snapshot(user)
    run = start(40, "write hello\n" <> @success, executable: wrapper)
    eventually(fn -> File.exists?(ready) end, 1_000)
    configure([{"app", user, [2]}])
    File.write!(log, "")
    File.write!(release, "go")

    payloads = reported(40)
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, 40) == [] end)
    assert %Report.Finished{failure_reason: :push_failed, error: error} = List.last(payloads)
    assert error =~ "not shared with this workspace on this machine"
    refute Enum.any?(payloads, &match?(%Report.Pushed{}, &1))
    refute inspect(payloads, limit: :infinity, printable_limit: :infinity) =~ user

    after_revoke = String.split(File.read!(log), "\n", trim: true)

    refute Enum.any?(
             after_revoke,
             &(&1 =~ ~r/(^| )(push|fetch|ls-remote|upload-pack|receive-pack)( |$)/)
           )

    assert snapshot(user) == before
    assert ref(user, @branch) |> elem(0) == :error
    ledger = GitLedger.read(run)
    assert 40 in ledger["inherit"]

    configure([{"app", user, [1]}])
    start(41, @success)
    current = pushed(41)
    assert %{current | run_id: 40} == pushed(40)
    finished(41)
    assert ref(user, @branch) == {:ok, current.head_sha <> "\n"}
  end

  test "a changed path is reported without either path", %{root: root, user: user} do
    start(40, "write first\n" <> @success)
    pushed(40)
    finished(40)

    moved = Path.join(root, "private-new-checkout")
    git!(root, ["clone", "-q", user, moved])
    configure([{"app", moved, [1]}])
    start(41, "write second\n" <> @success)
    payloads = reported(41)
    text = inspect(payloads, limit: :infinity, printable_limit: :infinity)
    assert text =~ "local repository app now points to another path in the machine configuration"
    refute text =~ user
    refute text =~ moved
    assert %Report.Finished{status: :succeeded} = List.last(payloads)
  end

  test "a name that is not configured or not shared fails preparation", %{user: user} do
    configure([{"other", user, [1]}])
    start(40, @success)
    assert %{failure_reason: :workspace_prepare, error: error} = finished(40, :failed)
    assert error =~ "local repository app is not configured on this machine"

    configure([{"app", user, [2]}])
    start(41, @success)
    assert %{failure_reason: :workspace_prepare, error: error} = finished(41, :failed)
    assert error =~ "local repository app is not shared with this workspace on this machine"

    configure([{"app", Path.join(user, "missing"), [1]}])
    start(42, @success)
    assert %{failure_reason: :workspace_prepare, error: error} = finished(42, :failed)
    assert error =~ "unavailable on this machine: path does not exist"
    refute File.exists?(LocalRepos.cache_path("app"))
  end

  test "rescue branches from earlier conflicts are merged from the user's repository", %{
    user: user
  } do
    start(40, "write first\n" <> @success)
    pushed(40)
    finished(40)
    git!(user, ["switch", "-q", @branch])
    start(41, "write second\n" <> @success)
    conflict = pushed(41)
    finished(41, :failed)
    git!(user, ["switch", "-q", "main"])

    start(42, @success, rescues: [conflict.rescue_branch])
    report = pushed(42)
    assert report.rescue_branch == nil
    assert ref(user, @branch) == {:ok, conflict.head_sha <> "\n"}
    finished(42)
  end
end

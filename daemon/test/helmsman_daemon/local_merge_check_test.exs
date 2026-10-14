defmodule HelmsmanDaemon.LocalMergeCheckTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  import HelmsmanDaemon.LocalRepoHelpers
  alias HelmsmanDaemon.{Connection, LocalMergeCheck}
  alias HelmsmanProtocol.Messages

  @branch "hm/1/bos-1"
  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)

  setup %{tmp_dir: tmp_dir} do
    isolate_home(tmp_dir)
    user = user_repo()
    configure([{"app", user, [1]}])
    %{user: user}
  end

  # A task branch in the user's repository, one commit ahead of main.
  defp task_branch(user, branch \\ @branch) do
    git!(user, ["switch", "-q", "-c", branch])
    head = commit(user, String.replace(branch, "/", "-") <> ".txt", "task\n", "task work")
    git!(user, ["switch", "-q", "main"])
    head
  end

  defp watch(head, branch \\ @branch, base \\ "main"),
    do: %{branch: branch, head_sha: head, base_branch: base}

  defp merged(report), do: Map.new(report.results, &{&1.branch, &1.merged})

  defp start_checker(opts) do
    test = self()

    start_supervised!(
      {LocalMergeCheck,
       Keyword.merge([repo_status_sender: &send(test, {:repo_status, &1})], opts)}
    )
  end

  test "a join reply with a watch list is followed by repo_status", %{user: user} do
    seed_cache(user)
    head = task_branch(user)
    start_execution()
    start_supervised!({LocalMergeCheck, []})

    client =
      start_supervised!(
        {Connection,
         test_mode?: true,
         credentials: credentials(),
         stop: fn code -> raise "unexpected daemon exit #{code}" end,
         heartbeat_interval_ms: 100_000,
         rotation_interval_ms: 100_000}
      )

    accept_connect(client)

    assert_join(
      "daemon:1",
      _payload,
      {:ok,
       %{
         "daemon_id" => 1,
         "runtimes" => [
           %{
             "workspace_id" => 1,
             "workspace_slug" => "bos",
             "provider" => "claude",
             "runtime_id" => 3
           }
         ],
         "terminate_run_ids" => [],
         "local_repositories" => [
           %{
             "workspace_id" => 1,
             "name" => "app",
             "local_repository_id" => 5,
             "watch" => [%{"branch" => @branch, "head_sha" => head, "base_branch" => "main"}]
           }
         ]
       }},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, claim, 1_000)
    reply(client, claim, {:ok, %{"runs" => []}})
    assert_push("daemon:1", "repo_status", payload, ref, 5_000)
    reply(client, ref, :ok)

    assert {:ok, %Report.RepoStatus{workspace_id: 1, name: "app", results: [result]}} =
             Messages.decode("repo_status", payload)

    assert %{branch: @branch, head_sha: ^head, merged: :no} = result
  end

  test "merge --no-ff is yes, a squash merge is no, missing commits or bases are unknown", %{
    user: user
  } do
    seed_cache(user)
    merged = task_branch(user)
    squashed = task_branch(user, "hm/1/bos-2")
    git!(user, ["merge", "-q", "--no-ff", "-m", "merge", @branch])
    git!(user, ["merge", "-q", "--squash", "hm/1/bos-2"])
    git!(user, ["commit", "-q", "-m", "squash"])
    before = snapshot(user)

    assert {:ok, report} =
             LocalMergeCheck.check(1, "app", [
               watch(merged),
               watch(squashed, "hm/1/bos-2"),
               watch(String.duplicate("a", 40), "hm/1/bos-3"),
               watch(merged, "hm/1/bos-4", "no-such-base"),
               watch("--output=/tmp/x", "hm/1/bos-5")
             ])

    assert merged(report) == %{
             @branch => :yes,
             "hm/1/bos-2" => :no,
             "hm/1/bos-3" => :unknown,
             "hm/1/bos-4" => :unknown,
             "hm/1/bos-5" => :unknown
           }

    assert snapshot(user) == before
  end

  test "no cache, or a repository no longer shared, is never fetched", %{user: user} do
    head = task_branch(user)
    assert {:ok, report} = LocalMergeCheck.check(1, "app", [watch(head)])
    assert merged(report) == %{@branch => :unknown}
    refute File.exists?(HelmsmanDaemon.LocalRepos.cache_path("app"))

    configure([{"app", user, [2]}])
    assert LocalMergeCheck.check(1, "app", [watch(head)]) == :skip
  end

  test "sharing revoked while waiting for the cache lock skips the check", %{user: user} do
    cache = seed_cache(user)
    head = task_branch(user)
    test = self()

    holder =
      spawn(fn ->
        HelmsmanDaemon.RepoCache.with_repo_lock(cache, fn ->
          send(test, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked
    check = Task.async(fn -> LocalMergeCheck.check(1, "app", [watch(head)]) end)
    Process.sleep(200)
    configure([{"app", user, [2]}])
    send(holder, :release)
    assert Task.await(check, 10_000) == :skip
    refute File.exists?(Path.join(cache, "FETCH_HEAD"))
  end

  test "sharing revoked right before the fetch skips the check", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    cache = seed_cache(user)
    head = task_branch(user)
    git = pausing_git(tmp_dir, "remote get-url origin")

    check =
      Task.async(fn ->
        LocalMergeCheck.check(1, "app", [watch(head)], executable: git.executable)
      end)

    eventually(fn -> File.exists?(git.ready) end, 1_000)
    configure([{"app", user, [2]}])
    File.write!(git.log, "")
    File.write!(git.release, "go")
    assert Task.await(check, 10_000) == :skip
    refute user_repo_access?(git.log)
    refute File.exists?(Path.join(cache, "FETCH_HEAD"))
  end

  test "rechecks the latest watch list on every interval", %{user: user} do
    seed_cache(user)
    head = task_branch(user)
    checker = start_checker(merge_check_interval_ms: 100)
    LocalMergeCheck.update([%{workspace_id: 1, name: "app", watch: [watch(head)]}])
    assert_receive {:repo_status, %{results: [%{merged: :no}]}}, 5_000

    git!(user, ["merge", "-q", "--no-ff", "-m", "merge", @branch])
    assert_receive {:repo_status, %{results: [%{merged: :yes}]}}, 5_000
    assert_receive {:repo_status, %{results: [%{merged: :yes}]}}, 5_000

    LocalMergeCheck.update([%{workspace_id: 1, name: "app", watch: []}])
    # A check already in flight still reports; once it is done nothing is pending.
    eventually(fn -> idle?(checker) end, 1_000)
    flush()

    send(checker, :tick)
    assert idle?(checker)
    refute_received {:repo_status, _}
  end

  defp idle?(checker) do
    state = :sys.get_state(checker)
    state.task == nil and state.queue == []
  end

  test "a local run's finalization triggers one check with the latest watch list", %{user: user} do
    start_execution()
    start_checker(merge_check_interval_ms: 3_600_000)
    base = git!(user, ["rev-parse", "main"])
    LocalMergeCheck.update([%{workspace_id: 1, name: "app", watch: [watch(base)]}])
    assert_receive {:repo_status, %{results: [%{merged: :unknown}]}}, 5_000

    run = %{spec(40) | repo: local_repo()}
    scenario = scenario!(Path.join(Paths.home(), "scenario"), "write hello\n" <> @success)
    run = %{run | agent: %{run.agent | custom_args: [scenario]}}
    {:ok, _} = Runs.start_run(run, reporter: TestReporter, push_backoff_ms: [0, 0])

    assert_receive {:report, 40, %Report.Finished{status: :succeeded}, _, _, _}, 20_000
    assert_receive {:repo_status, %{workspace_id: 1, name: "app", results: [result]}}, 5_000
    assert %{branch: @branch, head_sha: ^base, merged: :yes} = result
    refute_receive {:repo_status, _}, 200
  end

  defp flush do
    receive do
      {:repo_status, _} -> flush()
    after
      0 -> :ok
    end
  end
end

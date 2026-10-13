defmodule HelmsmanDaemon.CleanupTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  import HelmsmanDaemon.GitHelpers
  import ExUnit.CaptureLog
  alias HelmsmanDaemon.{Cleanup, Connection, GitLedger, RepoCache}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    f = fixture(root)
    spec = repo_spec(f)
    assert {:ok, state} = prepare(spec)
    %{fixture: f, spec: spec, state: state}
  end

  defp run_cleanup(state, opts \\ []) do
    heads = Keyword.get(opts, :heads, [git!(state.git, state.path, ["rev-parse", "HEAD"])])
    base = Keyword.get(opts, :base, "main")
    owner = self()

    check = fn items ->
      send(owner, {:cleanup_items, items})

      {:ok, reply} =
        Reply.CleanupCheck.new(
          results:
            Enum.map(items, fn item ->
              item
              |> Map.from_struct()
              |> Map.merge(%{deletable: true, base_branch: base, pushed_heads: heads})
            end)
        )

      {:ok, reply}
    end

    Cleanup.run(check, opts)
  end

  defp snapshot(f) do
    %{
      file: File.read!(Path.join(f.seed, "base.txt")),
      head: git!(f.git, f.seed, ["rev-parse", "HEAD"]),
      refs: git!(f.git, f.seed, ["for-each-ref"]),
      worktrees: git!(f.git, f.seed, ["worktree", "list", "--porcelain"])
    }
  end

  test "GitHub cache is deleted with its task branch and empty ledger", %{
    state: state,
    spec: spec,
    fixture: f
  } do
    before = snapshot(f)
    # The existing prepare fixture uses a local bare remote and the GitHub cache layout.
    Paths.private_dir!(Path.dirname(GitLedger.path(spec)))
    File.write!(GitLedger.path(spec), Jason.encode!(%{"inherit" => [], "outbox" => []}))
    assert :ok = run_cleanup(state)

    assert_receive {:cleanup_items,
                    [%HelmsmanProtocol.CleanupItem{workspace_id: 1, ident: "BOS-1"}]}

    refute File.exists?(state.path)
    refute File.exists?(GitLedger.path(spec))
    assert File.dir?(state.cache)
    refute git!(state.git, state.cache, ["for-each-ref", "refs/heads"]) =~ "hm/1/bos-1"
    assert snapshot(f) == before
  end

  test "local cache cleanup leaves the user's task branch and repository unchanged", %{
    fixture: f,
    state: state
  } do
    git!(state.git, state.cache, ["worktree", "remove", state.path])
    git!(f.git, f.seed, ["branch", "hm/1/bos-1"])
    cache = Path.join([Paths.home(), "repos", "local", "user-app.git"])
    File.mkdir_p!(Path.dirname(cache))
    git!(f.git, Paths.home(), ["init", "--bare", cache])
    git!(f.git, cache, ["fetch", f.seed, "+refs/heads/*:refs/remotes/origin/*"])

    git!(f.git, cache, [
      "worktree",
      "add",
      "--no-track",
      "-b",
      "hm/1/bos-1",
      state.path,
      "refs/remotes/origin/main"
    ])

    before = snapshot(f)
    assert :ok = run_cleanup(%{state | cache: cache})
    refute File.exists?(state.path)
    assert git!(f.git, cache, ["for-each-ref", "refs/heads"]) == ""
    assert snapshot(f) == before
    assert git!(f.git, f.seed, ["for-each-ref", "refs/heads/hm/1/bos-1"]) != ""
  end

  for defect <- [
        :user_worktree,
        :worktree_symlink,
        :parent_symlink,
        :home_symlink,
        :wrong_branch,
        :outside_cache,
        :cache_symlink,
        :non_bare,
        :reverse_mismatch,
        :dotgit_symlink
      ] do
    test "invalid layout #{defect} is never queried and preserves user repository", %{
      fixture: f,
      state: state
    } do
      defect = unquote(defect)
      state = damage_layout(defect, state, f)
      before = snapshot(f)
      log = capture_log(fn -> assert :ok = run_cleanup(state) end)
      refute_receive {:cleanup_items, _}
      assert snapshot(f) == before
      assert File.exists?(state.path)
      assert(log =~ "Cleanup preserved")
    end
  end

  defp damage_layout(:user_worktree, state, f) do
    git!(state.git, state.cache, ["worktree", "remove", state.path])
    git!(f.git, f.seed, ["worktree", "add", "-b", "hm/1/bos-1", state.path])
    state
  end

  defp damage_layout(:wrong_branch, state, _f) do
    git!(state.git, state.path, ["switch", "-c", "other"])
    state
  end

  defp damage_layout(:worktree_symlink, state, _f) do
    moved = state.path <> "-target"
    File.rename!(state.path, moved)
    File.ln_s!(moved, state.path)
    state
  end

  defp damage_layout(:parent_symlink, state, _f) do
    parent = Path.dirname(state.path)
    File.rename!(parent, parent <> "-target")
    File.ln_s!(parent <> "-target", parent)
    state
  end

  defp damage_layout(:home_symlink, state, _f) do
    home = Paths.home()
    link = Path.join(home, "home-link")
    File.ln_s!(home, link)
    System.put_env("HELMSMAN_HOME", link)
    state
  end

  defp damage_layout(:outside_cache, state, f) do
    moved = Path.join(Path.dirname(f.seed), "outside.git")
    File.rename!(state.cache, moved)
    metadata = Path.join([moved, "worktrees", Path.basename(state.path)])
    File.write!(Path.join(state.path, ".git"), "gitdir: #{metadata}\n")
    state
  end

  defp damage_layout(:cache_symlink, state, _f) do
    File.rename!(state.cache, state.cache <> "-target")
    File.ln_s!(state.cache <> "-target", state.cache)
    state
  end

  defp damage_layout(:non_bare, state, _f) do
    git!(state.git, state.cache, ["config", "core.bare", "false"])
    state
  end

  defp damage_layout(:reverse_mismatch, state, f) do
    metadata = git!(state.git, state.path, ["rev-parse", "--absolute-git-dir"])
    File.write!(Path.join(metadata, "gitdir"), Path.join(f.seed, ".git") <> "\n")
    state
  end

  defp damage_layout(:dotgit_symlink, state, _f) do
    dotgit = Path.join(state.path, ".git")
    File.rename!(dotgit, dotgit <> "-target")
    File.ln_s!(dotgit <> "-target", dotgit)
    state
  end

  for field <- ["inherit", "outbox"] do
    test "nonempty ledger #{field} prevents deletion", %{state: state, spec: spec} do
      GitLedger.write(
        spec,
        Map.put(%{"inherit" => [], "outbox" => []}, unquote(field), [%{"run_id" => 3}])
      )

      log = capture_log(fn -> assert :ok = run_cleanup(state) end)
      assert File.exists?(state.path)
      assert File.exists?(GitLedger.path(spec))
      assert log =~ "pending_or_unsafe_ledger"
    end
  end

  test "untracked and uncommitted changes are preserved", %{state: state} do
    File.write!(Path.join(state.path, "private.txt"), "unsaved")
    log = capture_log(fn -> assert :ok = run_cleanup(state) end)
    assert log =~ "uncommitted_or_untracked_changes"
    assert File.read!(Path.join(state.path, "private.txt")) == "unsaved"
    git!(state.git, state.path, ["add", "private.txt"])
    assert :ok = run_cleanup(state)
    assert File.exists?(state.path)
  end

  for ignore_source <- [:gitignore, :cache_exclude] do
    test "ignored untracked files from #{ignore_source} preserve the delivered worktree", %{
      state: state,
      fixture: f,
      spec: spec
    } do
      ignore_files(unquote(ignore_source), state, f)

      head = git!(state.git, state.path, ["rev-parse", "HEAD"])
      secret = Path.join(state.path, "local-secret.txt")
      nested = Path.join([state.path, "local-data", "nested", "notes.txt"])
      File.mkdir_p!(Path.dirname(nested))
      File.write!(secret, "keep local secret")
      File.write!(nested, "keep generated notes")
      Paths.private_dir!(Path.dirname(GitLedger.path(spec)))
      File.write!(GitLedger.path(spec), Jason.encode!(%{"inherit" => [], "outbox" => []}))
      refs = git!(state.git, state.cache, ["for-each-ref"])
      worktrees = git!(state.git, state.cache, ["worktree", "list", "--porcelain"])

      assert git!(state.git, state.path, ["status", "--porcelain=v1", "--untracked-files=all"]) ==
               ""

      log = capture_log(fn -> assert :ok = run_cleanup(state, heads: [head]) end)
      assert File.read!(secret) == "keep local secret"
      assert File.read!(nested) == "keep generated notes"
      assert File.exists?(GitLedger.path(spec))
      assert git!(state.git, state.path, ["rev-parse", "HEAD"]) == head
      assert git!(state.git, state.cache, ["for-each-ref"]) == refs
      assert git!(state.git, state.cache, ["worktree", "list", "--porcelain"]) == worktrees
      assert log =~ "uncommitted_or_untracked_changes"
    end
  end

  defp ignore_files(:gitignore, state, f) do
    commit(
      f.git,
      state.path,
      ".gitignore",
      "local-secret.txt\nlocal-data/\n",
      "ignore local files"
    )
  end

  defp ignore_files(:cache_exclude, state, _f) do
    File.write!(Path.join([state.cache, "info", "exclude"]), "local-secret.txt\nlocal-data/\n")
  end

  for operation <- ~w(MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD rebase-merge rebase-apply sequencer) do
    test "unfinished #{operation} is preserved", %{state: state} do
      metadata = git!(state.git, state.path, ["rev-parse", "--absolute-git-dir"])

      File.write!(
        Path.join(metadata, unquote(operation)),
        git!(state.git, state.path, ["rev-parse", "HEAD"])
      )

      log = capture_log(fn -> assert :ok = run_cleanup(state) end)
      assert File.exists?(state.path)
      assert log =~ "unfinished_git_operation"
    end
  end

  test "unpublished commits are preserved; a pushed descendant permits deletion", %{
    state: state,
    fixture: f
  } do
    base = git!(state.git, state.path, ["rev-parse", "HEAD"])
    head = commit(f.git, state.path, "new.txt", "new", "new")

    log =
      capture_log(fn ->
        assert :ok = run_cleanup(state, heads: [base, String.duplicate("f", 40)])
      end)

    assert File.exists?(state.path)
    assert log =~ "unpushed_commits"
    # A locally present descendant listed by the server includes HEAD.
    descendant = commit(f.git, state.path, "after.txt", "after", "after")
    git!(f.git, state.path, ["reset", "--hard", head])
    assert :ok = run_cleanup(state, heads: [descendant], base: nil)
    refute File.exists?(state.path)
  end

  test "no task commits: HEAD behind the remote base permits deletion", %{
    state: state,
    fixture: f
  } do
    newer = commit(f.git, f.seed, "later.txt", "later", "later base")
    git!(f.git, f.seed, ["push", "origin", "main"])
    git!(f.git, state.cache, ["fetch", "origin"])
    assert git!(f.git, state.cache, ["rev-parse", "refs/remotes/origin/main"]) == newer
    assert :ok = run_cleanup(state, heads: [])
    refute File.exists?(state.path)
  end

  for kind <- [:worktree, :repository] do
    test "busy #{kind} lock is skipped without waiting", %{state: state} do
      owner = self()

      holder =
        spawn_link(fn ->
          lock =
            if unquote(kind) == :worktree,
              do: &RepoCache.with_worktree_lock/2,
              else: &RepoCache.with_repo_lock/2

          key = if unquote(kind) == :worktree, do: state.path, else: state.cache

          lock.(key, fn ->
            send(owner, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked
      log = capture_log(fn -> assert :ok = run_cleanup(state) end)
      assert File.exists?(state.path)
      assert log =~ "busy"
      send(holder, :release)
      monitor = Process.monitor(holder)
      assert_receive {:DOWN, ^monitor, :process, ^holder, _}
      assert :ok = run_cleanup(state)
      refute File.exists?(state.path)
    end
  end

  test "failed worktree remove preserves path, branch and ledger", %{
    state: state,
    tmp_dir: root,
    spec: spec
  } do
    wrapper = Path.join(root, "refuse-remove")
    git = System.find_executable("git")

    File.write!(
      wrapper,
      "#!/bin/sh\ncase \" $* \" in *' worktree remove '*) exit 1;; esac\nexec '#{git}' \"$@\"\n"
    )

    File.chmod!(wrapper, 0o700)
    Paths.private_dir!(Path.dirname(GitLedger.path(spec)))
    File.write!(GitLedger.path(spec), Jason.encode!(%{"inherit" => [], "outbox" => []}))
    assert :ok = run_cleanup(state, cleanup_git_opts: [executable: wrapper])
    assert File.exists?(state.path)
    assert File.exists?(GitLedger.path(spec))
    assert git!(state.git, state.cache, ["for-each-ref", "refs/heads/hm/1/bos-1"]) != ""
  end

  test "layout is revalidated under locks after server response", %{state: state} do
    check = fn items ->
      git!(state.git, state.path, ["switch", "-c", "changed-during-check"])

      Reply.CleanupCheck.new(
        results:
          Enum.map(items, fn item ->
            item
            |> Map.from_struct()
            |> Map.merge(%{deletable: true, base_branch: "main", pushed_heads: []})
          end)
      )
    end

    assert :ok = Cleanup.run(check)
    assert File.exists?(state.path)
  end

  test "first join, injected daily timer and reconnect do not overlap rounds", %{state: state} do
    owner = self()

    gate = fn items ->
      send(owner, {:round, self(), items})

      receive do
        :finish -> {:error, :injected}
      end
    end

    start_supervised!(
      {Cleanup,
       cleanup_check: gate,
       cleanup_schedule: fn target, message, ms ->
         send(owner, {:scheduled, target, message, ms})
       end}
    )

    Cleanup.joined(HelmsmanProtocol.cleanup_version() - 1)
    refute_receive {:round, _, _}, 50
    Cleanup.joined(HelmsmanProtocol.cleanup_version())
    assert_receive {:scheduled, cleaner, :cleanup_tick, 86_400_000}
    assert_receive {:round, first, _}, 2_000
    Cleanup.joined(HelmsmanProtocol.cleanup_version())
    send(cleaner, :cleanup_tick)
    assert_receive {:scheduled, ^cleaner, :cleanup_tick, 86_400_000}
    refute_receive {:round, _, _}, 50
    send(first, :finish)
    eventually(fn -> :sys.get_state(cleaner).task == nil end)
    send(cleaner, :cleanup_tick)
    assert_receive {:round, second, _}, 2_000
    send(second, :finish)
    eventually(fn -> :sys.get_state(cleaner).task == nil end)
    Cleanup.disconnected()
    send(cleaner, :cleanup_tick)
    refute_receive {:round, _, _}, 50
    assert File.exists?(state.path)
  end

  test "Channel join starts cleanup and replies are decoded independently of runs", %{
    state: state
  } do
    start_execution()
    start_supervised!({Cleanup, cleanup_schedule: fn _, _, _ -> :ok end})

    client =
      start_supervised!(
        {Connection,
         test_mode?: true,
         credentials: credentials(),
         heartbeat_interval_ms: 100_000,
         rotation_interval_ms: 100_000}
      )

    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", _, claim, 1_000)
    reply(client, claim, {:ok, %{"runs" => []}})
    assert_push("daemon:1", "cleanup_check", payload, ref, 2_000)
    assert payload == %{"items" => [%{"workspace_id" => 1, "ident" => "BOS-1"}]}

    reply(
      client,
      ref,
      {:ok,
       %{
         "results" => [
           %{
             "workspace_id" => 1,
             "ident" => "BOS-1",
             "deletable" => true,
             "base_branch" => "main",
             "pushed_heads" => []
           }
         ]
       }}
    )

    eventually(fn -> not File.exists?(state.path) end)
  end

  for failure <- [:timeout, :disconnect] do
    test "Channel #{failure} returns error without retrying cleanup", %{state: state} do
      start_execution()

      client =
        start_supervised!(
          {Connection,
           test_mode?: true,
           credentials: credentials(),
           push_timeout_ms: 80,
           heartbeat_interval_ms: 100_000,
           rotation_interval_ms: 100_000,
           reconnect_after_ms: [100_000]}
        )

      accept_connect(client)

      assert_join(
        "daemon:1",
        _,
        {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
        1_000
      )

      assert_push("daemon:1", "claim", _, claim, 1_000)
      reply(client, claim, {:ok, %{"runs" => []}})

      caller =
        Task.async(fn -> Connection.cleanup_check([%{workspace_id: 1, ident: "BOS-1"}]) end)

      assert_push("daemon:1", "cleanup_check", _, _, 1_000)

      if unquote(failure) == :disconnect do
        require Slipstream.Signatures

        send(
          client,
          Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed})
        )

        assert Task.await(caller) == {:error, :disconnected}
      else
        assert Task.await(caller) == {:error, :transport}
      end

      refute_push("daemon:1", "cleanup_check", _, 100)
      assert File.exists?(state.path)
    end
  end

  test "old connection does not start cleanup or send cleanup_check" do
    start_execution()
    owner = self()
    start_supervised!({Cleanup, cleanup_check: fn _ -> send(owner, :unexpected_check) end})
    version = HelmsmanProtocol.cleanup_version() - 1

    client =
      start_supervised!(
        {Connection, test_mode?: true, credentials: credentials(), protocol_version: version}
      )

    accept_connect(client)

    assert_join(
      "daemon:1",
      join,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert join["protocol"] == version
    assert_push("daemon:1", "claim", _, claim, 1_000)
    reply(client, claim, {:ok, %{"runs" => []}})

    assert {:error, {:not_in_version, ^version}} =
             Connection.cleanup_check([%{workspace_id: 1, ident: "BOS-1"}])

    refute_push("daemon:1", "cleanup_check", _, 50)
    refute_receive :unexpected_check
  end
end

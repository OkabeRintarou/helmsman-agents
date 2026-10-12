defmodule HelmsmanDaemon.WorkspaceGitTest do
  use HelmsmanDaemon.Case, async: false
  alias HelmsmanDaemon.{GitWorkspace, Paths}
  import HelmsmanDaemon.GitHelpers
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    fixture = fixture(root)
    %{fixture: fixture, spec: repo_spec(fixture)}
  end

  test "new task starts from remote main with only task heads in bare cache", %{
    fixture: f,
    spec: spec
  } do
    assert {:ok, state} = prepare(spec)
    assert state.path == Path.join([Paths.home(), "work", "1", "BOS-1"])
    assert git!(state.git, state.path, ["branch", "--show-current"]) == spec.repo.branch
    assert state.remote_base == git!(f.git, f.seed, ["rev-parse", "main"])

    assert git!(state.git, state.cache, ["for-each-ref", "--format=%(refname)", "refs/heads/"]) ==
             "refs/heads/" <> spec.repo.branch

    assert Bitwise.band(File.stat!(state.path).mode, 0o777) == 0o700
  end

  test "existing remote task is used on a new machine and workspace identities stay separate", %{
    fixture: f,
    spec: spec
  } do
    sha = commit(f.git, f.seed, "remote.txt", "remote", "remote task")
    push(f, "HEAD", spec.repo.branch)
    assert {:ok, one} = prepare(spec)
    assert git!(one.git, one.path, ["rev-parse", "HEAD"]) == sha

    other = %{
      spec
      | workspace: %{spec.workspace | id: 9, slug: "renamed"},
        repo: %{spec.repo | branch: "hm/9/bos-1"}
    }

    assert {:ok, two} = prepare(other)
    assert two.path != one.path
    assert two.cache == one.cache
    commit(one.git, one.path, "one", "one", "one")
    commit(two.git, two.path, "two", "two", "two")
    git!(one.git, one.path, ["push", "origin", "HEAD:refs/heads/" <> spec.repo.branch])
    git!(two.git, two.path, ["push", "origin", "HEAD:refs/heads/hm/9/bos-1"])
    refute File.exists?(Path.join(one.path, "two"))
    refute File.exists?(Path.join(two.path, "one"))
    renamed = %{spec | workspace: %{spec.workspace | slug: "new-slug"}}
    assert {:ok, reused} = prepare(renamed)
    assert reused.path == one.path
  end

  test "repository rename reuses cache and worktree; rebinding preserves both", %{
    tmp_dir: root,
    fixture: f,
    spec: spec
  } do
    assert {:ok, original} = prepare(spec)
    assert original.cache == Path.join([Paths.home(), "repos", "file", "123456789.git"])
    renamed_remote = Path.join(root, "renamed.git")
    File.rename!(f.remote, renamed_remote)
    renamed = %{spec | repo: %{spec.repo | clone_url: "file://" <> renamed_remote}}
    assert {:ok, same} = prepare(renamed)
    assert same.path == original.path
    assert same.cache == original.cache
    assert git!(same.git, same.cache, ["remote", "get-url", "origin"]) == renamed.repo.clone_url

    assert Enum.any?(same.events, fn {:status, event} ->
             event.level == :info and event.message =~ "repository URL changed"
           end)

    File.write!(Path.join(same.path, "important"), "keep")
    config = File.read!(Path.join(same.cache, "config"))
    rebound = %{renamed | repo: %{renamed.repo | github_repository_id: 987_654_321}}
    assert {:error, {:workspace_prepare, error}} = prepare(rebound)
    assert error =~ "another repository cache"
    assert File.read!(Path.join(same.path, "important")) == "keep"
    assert File.read!(Path.join(same.cache, "config")) == config
    assert {:ok, restored} = prepare(renamed)
    assert restored.path == same.path
  end

  test "missing base fails without creating a worktree", %{spec: spec} do
    spec = %{spec | repo: %{spec.repo | base_branch: "develop"}}
    assert {:error, {:workspace_prepare, error}} = prepare(spec)
    assert error =~ "develop"
    refute File.exists?(GitWorkspace.worktree_path(spec))
  end

  test "uncommitted files and unfinished merges are preserved with a remote baseline", %{
    fixture: f,
    spec: spec
  } do
    assert {:ok, state} = prepare(spec)
    File.write!(Path.join(state.path, "notes"), "unfinished")
    commit(f.git, f.seed, "remote.txt", "remote", "advance")
    push(f, "HEAD", spec.repo.branch)
    assert {:ok, again} = prepare(spec)
    assert File.read!(Path.join(again.path, "notes")) == "unfinished"
    refute File.exists?(Path.join(again.path, "remote.txt"))
    assert again.remote_base == git!(f.git, f.seed, ["rev-parse", "HEAD"])
    assert inspect(again.events) =~ "uncommitted"
  end

  test "local ahead is retained, behind fast-forwards, divergence merges without losing commits",
       %{fixture: f, spec: spec} do
    push(f, "main", spec.repo.branch)
    assert {:ok, state} = prepare(spec)
    local = commit(state.git, state.path, "local", "local", "local")
    assert {:ok, ahead} = prepare(spec)
    assert git!(ahead.git, ahead.path, ["rev-parse", "HEAD"]) == local
    remote = commit(f.git, f.seed, "remote", "remote", "remote")
    push(f, "HEAD", spec.repo.branch)
    assert {:ok, merged} = prepare(spec)
    assert GitWorkspace.ancestor?(merged, local, "HEAD")
    assert GitWorkspace.ancestor?(merged, remote, "HEAD")
    git!(merged.git, merged.path, ["push", "origin", "HEAD:refs/heads/" <> spec.repo.branch])
    git!(f.git, f.seed, ["fetch", "origin"])
    git!(f.git, f.seed, ["reset", "--hard", "origin/" <> spec.repo.branch])
    newest = commit(f.git, f.seed, "new", "new", "new")
    push(f, "HEAD", spec.repo.branch)
    assert {:ok, behind} = prepare(spec)
    assert git!(behind.git, behind.path, ["rev-parse", "HEAD"]) == newest
  end

  test "divergence conflict is left for the Agent and an existing merge is preserved", %{
    fixture: f,
    spec: spec
  } do
    push(f, "main", spec.repo.branch)
    assert {:ok, state} = prepare(spec)
    commit(state.git, state.path, "base.txt", "local\n", "local")
    remote = commit(f.git, f.seed, "base.txt", "remote\n", "remote")
    push(f, "HEAD", spec.repo.branch)
    assert {:ok, conflict} = prepare(spec)
    assert git!(conflict.git, conflict.path, ["rev-parse", "MERGE_HEAD"]) == remote
    assert inspect(conflict.events) =~ "conflict"
    contents = File.read!(Path.join(conflict.path, "base.txt"))
    assert {:ok, again} = prepare(spec)
    assert File.read!(Path.join(again.path, "base.txt")) == contents
    assert inspect(again.events) =~ "unfinished merge"
  end

  test "occupied directories, other caches, and duplicate checkouts are never overwritten", %{
    spec: spec
  } do
    path = GitWorkspace.worktree_path(spec)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "important"), "keep")
    assert {:error, {:workspace_prepare, error}} = prepare(spec)
    assert error =~ "manually"
    assert File.read!(Path.join(path, "important")) == "keep"
    File.rm_rf!(path)
    assert {:ok, state} = prepare(spec)
    alternate = Path.join(Paths.home(), "alternate")
    git!(state.git, state.cache, ["worktree", "move", state.path, alternate])
    assert {:error, {:workspace_prepare, error}} = prepare(spec)
    assert error =~ "already used by worktree"
    assert File.exists?(alternate)
  end

  test "stale private index lock is removed and shared locks remain", %{spec: spec} do
    assert {:ok, state} = prepare(spec)
    git_dir = git!(state.git, state.path, ["rev-parse", "--absolute-git-dir"])
    lock = Path.join(git_dir, "index.lock")
    File.write!(lock, "stale")
    assert {:ok, again} = prepare(spec)
    refute File.exists?(lock)
    assert inspect(again.events) =~ "index.lock"
    shared = Path.join(state.cache, "packed-refs.lock")
    File.write!(shared, "do not remove")
    prepare(spec)
    assert File.read!(shared) == "do not remove"
  end

  test "origin credentials are repaired even when the redacted URL already equals clone_url", %{
    fixture: f,
    spec: spec
  } do
    assert {:ok, state} = prepare(spec)

    git!(state.git, state.cache, [
      "remote",
      "set-url",
      "origin",
      "file://user:PRIVATE@" <> f.remote
    ])

    assert {:ok, repaired} = prepare(spec)
    refute File.read!(Path.join(repaired.cache, "config")) =~ "user:PRIVATE@"

    assert git!(repaired.git, repaired.cache, ["remote", "get-url", "origin"]) ==
             spec.repo.clone_url

    assert inspect(repaired.events) =~ "removed credentials"
  end

  test "preparation timeout kills upload-pack and becomes workspace_prepare", %{
    tmp_dir: root,
    spec: spec
  } do
    wrapper = Path.join(root, "upload-pack")
    File.write!(wrapper, "#!/bin/sh\nsleep 20\n")
    File.chmod!(wrapper, 0o700)

    assert {:error, {:workspace_prepare, error}} =
             prepare(spec, prepare_timeout_ms: 1000, fetch_args: ["--upload-pack=" <> wrapper])

    assert error == "repository preparation exceeded 8 minutes"
  end

  test "fetch authentication renews once, succeeds with new token, and preserves origin safety",
       %{tmp_dir: root, spec: spec} do
    executable = System.find_executable("git")
    wrapper = Path.join(root, "git")

    File.write!(
      wrapper,
      "#!/bin/sh\ncase \" $* \" in\n*' fetch '*) if [ \"$HELMSMAN_GIT_TOKEN\" != fresh ]; then echo 'fatal: Authentication failed' >&2; exit 128; fi ;;\nesac\nexec '#{executable}' \"$@\"\n"
    )

    File.chmod!(wrapper, 0o700)
    owner = self()

    renew = fn id ->
      send(owner, {:renew, id})
      {:ok, %{token: "fresh"}}
    end

    assert {:ok, state} = prepare(spec, executable: wrapper, renew_token: renew)
    assert_receive {:renew, 1}
    refute_receive {:renew, _}
    assert state.git.token == "fresh"
    git!(state.git, state.cache, ["config", "--local", "credential.helper", "store"])

    git!(state.git, state.cache, [
      "config",
      "--local",
      "credential.https://github.com.helper",
      "store"
    ])

    git!(state.git, state.cache, [
      "remote",
      "set-url",
      "origin",
      "https://x-access-token:PRIVATE@invalid/repo.git"
    ])

    assert {:ok, sanitized} = prepare(spec, executable: wrapper, renew_token: renew)

    assert git!(sanitized.git, sanitized.cache, ["remote", "get-url", "origin"]) ==
             spec.repo.clone_url

    assert {:error, _} =
             HelmsmanDaemon.Git.run(
               ["config", "--local", "--get-regexp", "^credential\\."],
               state.cache,
               state.git
             )

    assert inspect(sanitized.events) =~ "removed credentials"
  end
end

defmodule HelmsmanDaemon.WorkspaceRescueTest do
  use HelmsmanDaemon.Case, async: false
  alias HelmsmanDaemon.GitWorkspace
  import HelmsmanDaemon.GitHelpers
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    fixture = fixture(root)
    spec = repo_spec(fixture)
    push(fixture, "main", spec.repo.branch)
    %{fixture: fixture, spec: spec}
  end

  test "rescue commits merge using Agent identity; deleted and already merged branches skip", %{
    fixture: f,
    spec: spec
  } do
    rescue_branch = spec.repo.branch <> "-run-31"
    sha = commit(f.git, f.seed, "rescue", "rescue", "rescue")
    push(f, "HEAD", rescue_branch)
    spec = %{spec | repo: %{spec.repo | rescue_branches: ["hm/1/bos-1-run-30", rescue_branch]}}
    assert {:ok, state} = prepare(spec, server_url: "https://hm.example.com:8443")
    assert GitWorkspace.ancestor?(state, sha, "HEAD")
    assert File.read!(Path.join(state.path, "rescue")) == "rescue"

    assert git!(state.git, state.path, ["log", "-1", "--format=%an <%ae>"]) ==
             "Fake <Fake@agents.hm.example.com>"

    assert inspect(state.events) =~ "no longer exists"
    assert {:ok, again} = prepare(%{spec | repo: %{spec.repo | rescue_branches: [rescue_branch]}})
    assert again.events == []
  end

  test "rescue conflict stops subsequent rescue and base merges and lists skipped branches", %{
    fixture: f,
    spec: spec
  } do
    assert {:ok, state} = prepare(spec)
    commit(state.git, state.path, "base.txt", "local", "local")
    first = spec.repo.branch <> "-run-31"
    second = spec.repo.branch <> "-run-35"
    sha = commit(f.git, f.seed, "base.txt", "rescue", "rescue")
    push(f, "HEAD", first)
    git!(f.git, f.seed, ["reset", "--hard", "main"])
    commit(f.git, f.seed, "later", "later", "later rescue")
    push(f, "HEAD", second)
    commit(f.git, f.seed, "base-update", "base-update", "new base")
    push(f, "HEAD", "main")

    spec = %{
      spec
      | repo: %{spec.repo | rescue_branches: [first, second]},
        trigger: %{spec.trigger | kind: "reopen", reason: "merge_conflict"}
    }

    assert {:ok, conflict} = prepare(spec)
    assert git!(conflict.git, conflict.path, ["rev-parse", "MERGE_HEAD"]) == sha
    assert inspect(conflict.events) =~ second
    refute File.exists?(Path.join(conflict.path, "later"))
    refute File.exists?(Path.join(conflict.path, "base-update"))
  end

  test "merge-conflict reopen merges base and retains conflicts", %{fixture: f, spec: spec} do
    assert {:ok, state} = prepare(spec)
    commit(state.git, state.path, "base.txt", "local", "local")
    sha = commit(f.git, f.seed, "base.txt", "upstream", "upstream")
    push(f, "HEAD", "main")
    spec = %{spec | trigger: %{spec.trigger | kind: "reopen", reason: "merge_conflict"}}
    assert {:ok, conflict} = prepare(spec)
    assert git!(conflict.git, conflict.path, ["rev-parse", "MERGE_HEAD"]) == sha
    assert inspect(conflict.events) =~ "conflict"
  end

  test "normal runs do not merge newly advanced base, reopen does", %{fixture: f, spec: spec} do
    assert {:ok, _state} = prepare(spec)
    commit(f.git, f.seed, "upstream", "upstream", "upstream")
    push(f, "HEAD", "main")
    assert {:ok, normal} = prepare(spec)
    refute File.exists?(Path.join(normal.path, "upstream"))
    spec = %{spec | trigger: %{spec.trigger | kind: "reopen", reason: "merge_conflict"}}
    assert {:ok, reopened} = prepare(spec)
    assert File.read!(Path.join(reopened.path, "upstream")) == "upstream"
  end
end

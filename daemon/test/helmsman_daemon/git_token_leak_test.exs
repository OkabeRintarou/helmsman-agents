defmodule HelmsmanDaemon.GitTokenLeakTest do
  use HelmsmanDaemon.Case, async: false
  alias HelmsmanDaemon.Adapters.{Claude, Codex, Fake}
  alias HelmsmanDaemon.{Env, Exec, Git, Paths}
  import HelmsmanDaemon.GitHelpers
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    fixture = fixture(root)
    spec = repo_spec(fixture)
    %{fixture: fixture, spec: spec}
  end

  test "prepared worktree, adapters, fake CLI environment and all daemon files contain no token",
       %{tmp_dir: root, spec: spec} do
    assert {:ok, state} = prepare(spec)
    run_dir = Paths.run(spec.run_id)

    for adapter <- [Claude, Codex, Fake] do
      assert {:ok, launch} = adapter.prepare(spec, run_dir, state.path)
      refute inspect(launch) =~ spec.repo.git_token
      refute inspect(launch.env) =~ "HELMSMAN_GIT_TOKEN"
      refute inspect(launch.env) =~ Path.join(run_dir, "askpass")
    end

    scenario = Path.join(root, "dump")
    File.write!(scenario, "dump_env\ndump_argv\nexit 0\n")
    launch_spec = %{spec | agent: %{spec.agent | custom_args: [scenario]}}
    assert {:ok, launch} = Fake.prepare(launch_spec, run_dir, state.path)

    assert {:ok, output} =
             Exec.command(launch.argv,
               cd: state.path,
               env: Enum.to_list(Env.child())
             )

    File.write!(Path.join(run_dir, "raw.log"), output)
    refute output =~ spec.repo.git_token
    refute output =~ "HELMSMAN_GIT_TOKEN="
    assert_no_token(Paths.home(), spec.repo.git_token)
  end

  test "global system and local helpers never run or change credential storage across fetch push rejection and retry",
       %{tmp_dir: root, fixture: f, spec: spec} do
    home = Path.join(root, "user-home")
    File.mkdir_p!(home)
    marker = Path.join(home, "helper-called")
    helper = Path.join(home, "helper")
    File.write!(helper, "#!/bin/sh\necho invoked >> '#{marker}'\n")
    File.chmod!(helper, 0o700)

    global =
      "[credential]\n helper = #{helper}\n[credential \"https://github.com\"]\n helper = #{helper}\n"

    File.write!(Path.join(home, ".gitconfig"), global)
    system = Path.join(home, "system-config")
    File.write!(system, global)
    credentials = Path.join(home, ".git-credentials")
    original = "https://user:original@github.com\n"
    File.write!(credentials, original)
    stat = File.stat!(credentials)
    base_env = System.get_env() |> Map.put("HOME", home) |> Map.put("GIT_CONFIG_SYSTEM", system)
    assert {:ok, state} = prepare(spec, base_env: base_env)
    git!(state.git, state.cache, ["config", "--local", "credential.helper", helper])

    git!(state.git, state.cache, [
      "config",
      "--local",
      "credential.https://github.com.helper",
      helper
    ])

    assert {:ok, state} = prepare(spec, base_env: base_env)

    assert {:error, _} =
             Git.run(
               ["config", "--local", "--get-regexp", "^credential\\."],
               state.cache,
               state.git
             )

    commit(state.git, state.path, "hello", "hello", "first")
    git!(state.git, state.path, ["push", "origin", "HEAD:refs/heads/" <> spec.repo.branch])
    hook = Path.join(f.remote, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\necho 'fatal: Authentication failed' >&2\nexit 1\n")
    File.chmod!(hook, 0o700)
    commit(state.git, state.path, "hello", "second", "second")
    wrapper = receive_pack(f)

    args = [
      "push",
      "--receive-pack=" <> wrapper,
      "origin",
      "HEAD:refs/heads/" <> spec.repo.branch
    ]

    assert {:error, {_, output}} = Git.run(args, state.path, state.git)
    assert Git.classify(output) == :authentication
    File.rm!(hook)
    fresh = %{state.git | token: "ghs_FRESH_PRIVATE_TOKEN"}
    git!(fresh, state.path, args)
    commit(f.git, f.seed, "remote", "remote", "diverge")
    push(f, "HEAD", spec.repo.branch <> "-other")
    git!(f.git, f.seed, ["push", "--force", "origin", "HEAD:refs/heads/" <> spec.repo.branch])
    commit(state.git, state.path, "local", "local", "local")
    assert {:error, {_, output}} = Git.run(args, state.path, fresh)
    assert Git.classify(output) == :rejected

    git!(fresh, state.path, ["push", "origin", "HEAD:refs/heads/" <> spec.repo.branch <> "-run-1"])

    refute File.exists?(marker)
    assert File.read!(credentials) == original
    assert File.stat!(credentials).mtime == stat.mtime
    assert_no_token(Paths.home(), spec.repo.git_token)
    assert_no_token(Paths.home(), fresh.token)
  end

  test "a local URL-specific helper cannot override the empty helper and askpass; no HTTPS request occurs",
       %{tmp_dir: root, fixture: f} do
    marker = Path.join(root, "helper-called")
    helper = Path.join(root, "helper")
    File.write!(helper, "#!/bin/sh\necho called >> '#{marker}'\n")
    File.chmod!(helper, 0o700)
    git!(f.git, f.seed, ["config", "credential.https://github.com.helper", helper])
    wrapper = Path.join(root, "credential-probe")
    executable = System.find_executable("git")

    File.write!(
      wrapper,
      "#!/bin/sh\nexec '#{executable}' \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" credential fill <<'INPUT'\nurl=https://github.com/acme/repo.git\n\nINPUT\n"
    )

    File.chmod!(wrapper, 0o700)
    context = Git.context(Paths.run(3), "private-credential", executable: wrapper)
    Git.write_askpass(context)
    assert {:ok, result} = Git.run(["fetch"], f.seed, context)
    assert result =~ "username=x-access-token"
    refute result =~ "private-credential"
    refute File.exists?(marker)
  end

  test "Agent pre-push hook is not executed with the token", %{fixture: f, spec: spec} do
    assert {:ok, state} = prepare(spec)
    marker = Path.join(Paths.home(), "hook-environment")
    hook = Path.join(state.cache, "hooks/pre-push")
    File.write!(hook, "#!/bin/sh\nenv > '#{marker}'\nexit 1\n")
    File.chmod!(hook, 0o700)
    commit(state.git, state.path, "hello", "hello", "hello")
    git!(state.git, state.path, ["push", "origin", "HEAD:refs/heads/" <> spec.repo.branch])

    assert git!(f.git, f.remote, ["rev-parse", "refs/heads/" <> spec.repo.branch]) ==
             git!(state.git, state.path, ["rev-parse", "HEAD"])

    refute File.exists?(marker)
    assert_no_token(Paths.home(), spec.repo.git_token)
  end

  defp assert_no_token(root, token) do
    Enum.each(File.ls!(root), fn name ->
      path = Path.join(root, name)

      if File.dir?(path),
        do: assert_no_token(path, token),
        else: refute(String.contains?(File.read!(path), token), path)
    end)
  end
end

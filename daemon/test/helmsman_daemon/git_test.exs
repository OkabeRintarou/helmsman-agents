defmodule HelmsmanDaemon.GitTest do
  use HelmsmanDaemon.Case, async: false
  alias HelmsmanDaemon.{Git, Paths}
  import HelmsmanDaemon.GitHelpers
  @moduletag :tmp_dir

  test "all command snapshots disable hooks, config and helpers; only network commands get token",
       %{tmp_dir: root} do
    token = "ghs_SECRET_INSTALL_TOKEN"

    env = %{
      "HOME" => root,
      "GIT_CONFIG_SYSTEM" => "/unsafe",
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "credential.helper",
      "GIT_CONFIG_VALUE_0" => "store",
      "GIT_CONFIG_PARAMETERS" => "'credential.helper=store'",
      "HELMSMAN_GIT_TOKEN" => "inherited",
      "GIT_ASKPASS" => "/unsafe",
      "SSH_ASKPASS" => "/unsafe",
      "SSH_ASKPASS_REQUIRE" => "force",
      "VSCODE_GIT_IPC_HANDLE" => "/unsafe",
      "VSCODE_IPC_HOOK_CLI" => "/unsafe",
      "HELMSMAN_HOME" => "/unsafe",
      "HELMSMAN_PROVIDER_API_KEY" => "hostile-sentinel",
      "HELMSMAN_RUN_TOKEN" => "hostile-sentinel"
    }

    context = Git.context(Paths.run(1), token, base_env: env)

    for command <- [
          "--version",
          "init",
          "config",
          "remote",
          "worktree",
          "rev-parse",
          "symbolic-ref",
          "merge-base",
          "merge",
          "status",
          "add",
          "commit",
          "fetch",
          "push",
          "ls-remote"
        ] do
      {argv, opts} = Git.command([command], root, context)

      assert Enum.take(argv, 7) == [
               System.find_executable("git"),
               "-c",
               "core.hooksPath=/dev/null",
               "-c",
               "credential.helper=",
               "-c",
               "gc.auto=0"
             ]

      refute Enum.any?(argv, &String.contains?(&1, token))
      assert hd(opts[:env]) == :clear
      actual = Map.new(tl(opts[:env]))
      assert actual["GIT_CONFIG_GLOBAL"] == "/dev/null"
      assert actual["GIT_CONFIG_NOSYSTEM"] == "1"
      assert actual["GIT_TERMINAL_PROMPT"] == "0"
      assert actual["LC_ALL"] == "C"
      refute Map.has_key?(actual, "GIT_CONFIG_SYSTEM")
      refute Map.has_key?(actual, "GIT_CONFIG_COUNT")
      refute Map.has_key?(actual, "GIT_CONFIG_PARAMETERS")

      for name <- ~w(SSH_ASKPASS SSH_ASKPASS_REQUIRE VSCODE_GIT_IPC_HANDLE VSCODE_IPC_HOOK_CLI
        HELMSMAN_HOME HELMSMAN_PROVIDER_API_KEY HELMSMAN_RUN_TOKEN),
          do: refute(Map.has_key?(actual, name))

      refute "hostile-sentinel" in Map.values(actual)

      if command in ["fetch", "push", "ls-remote"] do
        assert actual["HELMSMAN_GIT_TOKEN"] == token
        assert actual["GIT_ASKPASS"] == Path.join(Paths.run(1), "askpass")
        assert opts[:timeout] == 120_000
      else
        refute Map.has_key?(actual, "HELMSMAN_GIT_TOKEN")
        refute Map.has_key?(actual, "GIT_ASKPASS")
        assert opts[:timeout] == 30_000
      end
    end
  end

  test "askpass keeps no token on disk and returns username or environment token" do
    context = Git.context(Paths.run(1), "secret")
    path = Git.write_askpass(context)
    refute File.read!(path) =~ "secret"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700

    assert System.cmd(path, ["Username for 'https://github.com':"],
             env: [{"HELMSMAN_GIT_TOKEN", "secret"}]
           ) == {"x-access-token\n", 0}

    assert System.cmd(path, ["Password for 'https://x-access-token@github.com':"],
             env: [{"HELMSMAN_GIT_TOKEN", "secret"}]
           ) == {"secret\n", 0}
  end

  test "git errors classify recorded rejection, authentication and transport outputs" do
    samples = [
      {" ! [rejected]        HEAD -> hm/1/bos-1 (fetch first)\nerror: failed to push some refs",
       :rejected},
      {" ! [rejected]        main -> main (non-fast-forward)", :rejected},
      {"fatal: Authentication failed for 'https://github.com/acme/app.git/'", :authentication},
      {"fatal: unable to access 'https://github.com/acme/app.git/': Could not resolve host: github.com",
       :other},
      {"remote: policy rejected\n ! [remote rejected] HEAD -> main (pre-receive hook declined)",
       :other}
    ]

    for {sample, expected} <- samples, do: assert(Git.classify(sample) == expected)

    assert Git.redact("fatal: https://user:token@github.com/a and https://x@host/b") ==
             "fatal: https://github.com/a and https://host/b"
  end

  test "missing and old git give workspace preparation errors", %{tmp_dir: root} do
    fixture = fixture(root)
    spec = repo_spec(fixture)
    assert {:error, {:workspace_prepare, message}} = prepare(spec, executable: nil)
    assert message =~ "not found"
    old = Path.join(root, "old-git")
    File.write!(old, "#!/bin/sh\nprintf '%s\\n' 'git version 2.29.9'\n")
    File.chmod!(old, 0o700)
    assert {:error, {:workspace_prepare, message}} = prepare(spec, executable: old)
    assert message =~ "2.30"
    assert message =~ "2.29.9"
  end

  test "command timeout kills its group and errors redact token and URL", %{tmp_dir: root} do
    script = Path.join(root, "sleep-git")

    File.write!(
      script,
      "#!/bin/sh\necho https://user:secret@host/repo\necho \"$HELMSMAN_GIT_TOKEN\"\nsleep 20\n"
    )

    File.chmod!(script, 0o700)
    owner = self()

    context =
      Git.context(Paths.run(1), "secret",
        executable: script,
        command_timeout_ms: 100,
        on_start: fn pid -> send(owner, {:group, pid}) end
      )

    assert {:error, {:timeout, output}} = Git.run(["fetch"], root, context)
    assert_receive {:group, group}
    refute output =~ "secret"
    assert output =~ "https://host/repo"
    eventually(fn -> match?({:ok, []}, HelmsmanDaemon.ProcGroup.snapshot(group)) end)
  end
end

defmodule HelmsmanDaemon.LocalReposRootsTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.WebRepoHelpers
  alias HelmsmanDaemon.{CLI, Config, Connection, LocalMergeCheck, LocalRepos}
  alias HelmsmanProtocol.Messages

  setup do
    %{home: web_home()}
  end

  defp cli(args), do: with_io(fn -> CLI.run(args) end)

  defp roots_output do
    {0, output} = cli(["repos", "roots"])
    output
  end

  defp start_connection(opts) do
    start_execution()
    start_supervised!({LocalMergeCheck, repo_status_sender: fn _ -> :ok end})

    start_supervised!(
      {Connection,
       Keyword.merge(
         [
           test_mode?: true,
           credentials: credentials(),
           stop: fn code -> raise "unexpected daemon exit #{code}" end,
           heartbeat_interval_ms: 100_000,
           rotation_interval_ms: 100_000,
           config_check_interval_ms: 100
         ],
         opts
       )}
    )
  end

  defp join(client) do
    accept_connect(client)

    assert_join(
      "daemon:1",
      payload,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"runs" => []}})
    payload
  end

  defp reply_sync(client, ref),
    do:
      reply(client, ref, {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}})

  describe "scenarios" do
    test "by default web registration is off: register is disabled and sync reports false",
         %{home: home} do
      assert LocalRepos.roots() == []
      repo!(Path.join(home, "code/app"))
      HelmsmanDaemon.LocalRepoHelpers.served([{7, "acme"}])
      assert {:error, :disabled, _} = LocalRepos.register_from_web(register_push([]))
      refute File.exists?(config_path())
      assert roots_output() =~ "Web registration: disabled"

      client = start_connection([])
      assert join(client)["repo_registration"] == false
    end

    test "roots add ~/code: absolute path written, sync within the check interval reports true",
         %{home: home} do
      code = dir!(Path.join(home, "code"))
      client = start_connection([])
      assert join(client)["repo_registration"] == false

      assert {0, output} = cli(["repos", "roots", "add", "~/code"])

      assert output =~
               "You (the machine's owner) can now register git repositories under ~/code from the Helmsman web UI. Remove it with: helmsman repos roots remove ~/code"

      assert decoded()["repos"]["allowed_roots"] == [code]
      assert_push("daemon:1", "sync", payload, ref, 1_000)
      reply_sync(client, ref)
      assert {:ok, %Report.Sync{repo_registration: true}} = Messages.decode("sync", payload)
    end

    test "/, a relative path and a path inside the daemon home are ignored with reasons" do
      dir!(Path.join(Paths.home(), "repos"))
      allow!(["/", "relative/dir", "~/.helmsman/repos"])
      assert LocalRepos.roots() == []
      output = roots_output()
      assert output =~ "/\tignored: cannot be /"
      assert output =~ "relative/dir\tignored: must be absolute or start with ~"
      assert output =~ "~/.helmsman/repos\tignored: inside the daemon home directory"
      assert output =~ "Web registration: disabled"
    end

    test "a string instead of an array turns registration off; the daemon still starts",
         %{home: home} do
      dir!(Path.join(home, "code"))
      write_config!(~s([repos]\nallowed_roots = "~/code"\n))
      assert LocalRepos.roots() == []
      assert {:ok, _} = Config.load()
      output = roots_output()
      assert output =~ "allowed_roots in config.toml must be an array of strings"
      assert output =~ "Web registration: disabled"
    end

    test "sync carries only the boolean, never a root or a path below it", %{home: home} do
      code = dir!(Path.join(home, "code"))
      repo!(Path.join(code, "app"))
      allow!(["~/code"])
      client = start_connection([])
      payload = join(client)
      assert payload["repo_registration"] == true
      encoded = JSON.encode!(payload)
      refute encoded =~ "~/code"
      refute encoded =~ code

      File.touch!(config_path(), System.os_time(:second) + 5)
      assert_push("daemon:1", "sync", sync, ref, 1_000)
      reply_sync(client, ref)
      assert sync["repo_registration"] == true
      refute JSON.encode!(sync) =~ code
    end
  end

  describe "parsing" do
    test "~ and ~/x expand with the user's home", %{home: home} do
      x = dir!(Path.join(home, "x"))
      allow!(["~", "~/x"])
      assert LocalRepos.roots() == [%{label: "~", real: home}, %{label: "~/x", real: x}]
    end

    test "a root that is itself a symbolic link is valid; its real path is used", %{home: home} do
      target = dir!(Path.join(home, "data/a"))
      link!(target, Path.join(home, "code"))
      allow!(["~/code"])
      assert LocalRepos.roots() == [%{label: "~/code", real: target}]
    end

    test "items with the same real path keep the first", %{home: home} do
      code = dir!(Path.join(home, "code"))
      link!(code, Path.join(home, "alias"))
      allow!(["~/alias", code, "~/code/../code"])
      assert LocalRepos.roots() == [%{label: "~/alias", real: code}]
      assert roots_output() =~ "#{code}\tignored: same directory as ~/alias"
    end

    test "more than 16 items disable every root", %{home: home} do
      roots = for i <- 1..17, do: dir!(Path.join(home, "r#{i}"))
      allow!(roots)
      assert LocalRepos.roots() == []
      assert roots_output() =~ "more than 16 entries"

      allow!(Enum.take(roots, 16))
      assert length(LocalRepos.roots()) == 16
    end

    test "a missing directory, a file and a symbolic link loop", %{home: home} do
      File.write!(Path.join(home, "file"), "x")
      link!("loop2", Path.join(home, "loop1"))
      link!("loop1", Path.join(home, "loop2"))
      allow!(["~/missing", "~/file", "~/loop1"])
      assert LocalRepos.roots() == []
      output = roots_output()
      assert output =~ "~/missing\tignored: does not exist or is not a directory"
      assert output =~ "~/file\tignored: does not exist or is not a directory"
      assert output =~ "~/loop1\tignored: too many symbolic links"
    end

    test "[repos] that is not a table is malformed" do
      write_config!(~s(repos = "~/code"\n))
      assert LocalRepos.roots() == []
      assert roots_output() =~ "[repos] in config.toml must be a table"
    end
  end

  describe "real_path/1" do
    test "resolves relative and absolute links one component at a time", %{home: home} do
      real = dir!(Path.join(home, "a/real"))
      dir!(Path.join(real, "sub"))
      link!("real", Path.join(home, "a/rel"))
      link!(Path.join(home, "a"), Path.join(home, "abs"))
      link!("../a/rel/sub", Path.join(home, "b/chain"))

      assert LocalRepos.real_path(Path.join(home, "abs/rel/sub")) == {:ok, Path.join(real, "sub")}
      assert LocalRepos.real_path(Path.join(home, "b/chain")) == {:ok, Path.join(real, "sub")}
      # `..` applies after the link is resolved, as the kernel does.
      assert LocalRepos.real_path(Path.join(home, "b/chain/..")) == {:ok, real}
      assert LocalRepos.real_path(Path.join(home, "a/./real/../real")) == {:ok, real}
      assert {:error, :enoent} = LocalRepos.real_path(Path.join(home, "nope/x"))
      assert {:error, :enoent} = LocalRepos.real_path("relative")
    end

    test "40 links resolve, 41 fail; a loop fails", %{home: home} do
      dir!(Path.join(home, "target"))
      link!("target", Path.join(home, "l0"))
      for i <- 1..40, do: link!("l#{i - 1}", Path.join(home, "l#{i}"))

      assert LocalRepos.real_path(Path.join(home, "l39")) == {:ok, Path.join(home, "target")}
      assert LocalRepos.real_path(Path.join(home, "l40")) == {:error, :eloop}

      link!("y", Path.join(home, "x"))
      link!("x", Path.join(home, "y"))
      assert LocalRepos.real_path(Path.join(home, "x")) == {:error, :eloop}
    end
  end

  describe "roots add / remove" do
    test "adding an existing root fails, also through another spelling", %{home: home} do
      code = dir!(Path.join(home, "code"))
      link!(code, Path.join(home, "alias"))
      assert {0, _} = cli(["repos", "roots", "add", code])
      before = config!()

      assert {1, output} = cli(["repos", "roots", "add", "~/code"])
      assert output =~ "is already in allowed_roots"
      assert {1, output} = cli(["repos", "roots", "add", "~/alias"])
      assert output =~ "is already allowed as #{code}"
      assert config!() == before
    end

    test "an invalid directory is refused with the reason", %{home: home} do
      assert {1, output} = cli(["repos", "roots", "add", "~/missing"])
      assert output =~ "cannot be an allowed root: does not exist or is not a directory"
      assert {1, output} = cli(["repos", "roots", "add", Paths.home()])
      assert output =~ "inside the daemon home directory"
      refute File.exists?(config_path())
      assert {1, output} = cli(["repos", "roots", "add", "/"])
      assert output =~ "cannot be /"
      assert home != "/"
    end

    test "remove matches the written form or the expanded path", %{home: home} do
      code = dir!(Path.join(home, "code"))
      srv = dir!(Path.join(home, "srv"))
      allow!(["~/code", srv])

      assert {0, _} = cli(["repos", "roots", "remove", code])
      assert decoded()["repos"]["allowed_roots"] == [srv]
      assert {0, _} = cli(["repos", "roots", "remove", srv])
      assert decoded()["repos"]["allowed_roots"] == []
      assert {1, output} = cli(["repos", "roots", "remove", "~/code"])
      assert output =~ "~/code is not in allowed_roots"
    end

    test "other [repos] keys and the rest of config.toml are kept", %{home: home} do
      code = dir!(Path.join(home, "code"))

      write_config!("""
      max_concurrency = 2

      [repos]
      # comment
      future_key = "kept"
      limits = [1, 2]

      [credentials]
      store = "file"
      """)

      assert {0, _} = cli(["repos", "roots", "add", code])

      assert decoded() == %{
               "max_concurrency" => 2,
               "repos" => %{"future_key" => "kept", "limits" => [1, 2], "allowed_roots" => [code]},
               "credentials" => %{"store" => "file"}
             }

      assert {0, _} = cli(["repos", "roots", "remove", code])

      assert decoded()["repos"] == %{
               "future_key" => "kept",
               "limits" => [1, 2],
               "allowed_roots" => []
             }
    end

    test "a layout that cannot be rewritten safely is refused and left unchanged", %{home: home} do
      dir!(Path.join(home, "code"))

      for text <- [
            "repos.allowed_roots = []\n",
            "[repos]\nallowed_roots = []\n[repos.nested]\nx = 1\n"
          ] do
        write_config!(text)
        assert {1, output} = cli(["repos", "roots", "add", "~/code"])
        assert output =~ "cannot edit safely; edit it manually"
        assert config!() == text
      end

      write_config!(~s([repos]\nallowed_roots = "x"\n))
      assert {1, output} = cli(["repos", "roots", "add", "~/code"])
      assert output =~ "must be an array of strings; edit it manually"
    end
  end

  describe "reporting" do
    test "protocol 6 joins and syncs carry no repo_registration", %{home: home} do
      dir!(Path.join(home, "code"))
      allow!(["~/code"])
      client = start_connection(protocol_version: 6)
      payload = join(client)
      refute Map.has_key?(payload, "repo_registration")
      assert payload["protocol"] == 6
    end

    test "changing allowed_roots is reported by the next config check", %{home: home} do
      dir!(Path.join(home, "code"))
      client = start_connection([])
      assert join(client)["repo_registration"] == false
      refute_push("daemon:1", "sync", _, 250)

      allow!(["~/code"])
      assert_push("daemon:1", "sync", payload, ref, 1_000)
      reply_sync(client, ref)
      assert payload["repo_registration"] == true
      refute_push("daemon:1", "sync", _, 250)

      allow!([])
      File.touch!(config_path(), System.os_time(:second) + 5)
      assert_push("daemon:1", "sync", payload, ref, 1_000)
      reply_sync(client, ref)
      assert payload["repo_registration"] == false
    end
  end
end

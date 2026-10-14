defmodule HelmsmanDaemon.LocalReposWebTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import HelmsmanDaemon.WebRepoHelpers
  import HelmsmanDaemon.LocalRepoHelpers, only: [git!: 2, served: 1, user_repo: 2]
  alias HelmsmanDaemon.{CLI, ConfigLock, LocalRepos}

  defmodule RecordingLock do
    @moduledoc false
    def with_lock(fun, _opts) do
      send(self(), :lock_acquired)
      result = fun.()
      send(self(), :lock_released)
      {:ok, result}
    end
  end

  setup do
    home = web_home()
    code = dir!(Path.join(home, "code"))
    allow!(["~/code"])
    served([{7, "acme"}, {9, "beta"}])
    %{home: home, code: code}
  end

  defp register(attrs, opts \\ []), do: LocalRepos.register_from_web(register_push(attrs), opts)

  defp unchanged(fun) do
    before = config!()
    result = fun.()
    assert config!() == before
    result
  end

  defp code(attrs, opts \\ []) do
    case unchanged(fn -> register(attrs, opts) end) do
      {:error, code, _} -> code
      other -> other
    end
  end

  defp add_entry(name, path, extra \\ "") do
    write_config!(
      config!() <>
        "\n[[local_repositories]]\nname = #{inspect(name)}\npath = #{inspect(path)}\nworkspaces = [7]\n" <>
        extra
    )
  end

  describe "scenarios" do
    test "registration writes the real path and web keys, then reports success", %{code: code} do
      app = repo!(Path.join(code, "app"))

      log =
        capture_log([level: :info], fn ->
          assert register(
                   [request_id: "req_aaaaaaaaaaaaaaaaaaaaa", workspaces: [7]],
                   now: fn -> ~U[2026-10-14 06:40:00.123Z] end
                 ) == :ok
        end)

      assert configured() == [
               %{
                 "added_at" => "2026-10-14T06:40:00Z",
                 "added_from" => "web",
                 "name" => "app",
                 "path" => app,
                 "request_id" => "req_aaaaaaaaaaaaaaaaaaaaa",
                 "workspaces" => [7]
               }
             ]

      assert log =~
               "Local repository app registered from the web (request req_aaaaaaaaaaaaaaaaaaaaa)"

      refute log =~ code
      assert [%{name: "app", available: true, workspaces: [7]}] = LocalRepos.report([7])
    end

    test "a path with .. is invalid_path", %{home: home} do
      repo!(Path.join(home, "secret"))
      dir!(Path.join(home, "code/group"))
      assert code(path: "group/../../secret") == :invalid_path
    end

    test "a symbolic link anywhere on the path is outside_root", %{home: home, code: code} do
      repo!(Path.join(home, "secret/repo"))
      link!(Path.join(home, "secret"), Path.join(code, "link"))
      assert code(path: "link/repo") == :outside_root
      assert code(path: "link") == :outside_root
    end

    test "a linked worktree whose repository is outside the root is outside_root",
         %{home: home, code: code} do
      main = repo!(Path.join(home, "secret/main"))
      git!(main, ["worktree", "add", "-q", Path.join(code, "wt"), "-b", "wt"])
      assert code(path: "wt") == :outside_root
    end

    test "a root link changed while waiting for the lock: the new target is used",
         %{home: home} do
      a = dir!(Path.join(home, "data/a"))
      b = dir!(Path.join(home, "data/b"))
      repo!(Path.join(a, "app"))
      File.rm_rf!(Path.join(home, "code"))
      link!(a, Path.join(home, "code"))

      repoint = fn ->
        File.rm!(Path.join(home, "code"))
        File.ln_s!(b, Path.join(home, "code"))
      end

      assert code([], before_lock: repoint) == :missing
      refute config!() =~ a

      File.rm!(Path.join(home, "code"))
      File.ln_s!(a, Path.join(home, "code"))
      b_app = repo!(Path.join(b, "app"))
      assert register([], before_lock: repoint) == :ok
      assert [%{"path" => ^b_app}] = configured()
      refute config!() =~ a
    end

    test "removal waiting for the lock while the owner removes the only root is disabled",
         %{home: home} do
      add_entry("legacy", Path.join(home, "elsewhere"))

      before = config!()

      result =
        LocalRepos.remove_from_web(remove_push("legacy"),
          before_lock: fn ->
            with_io(fn -> 0 = CLI.run(["repos", "roots", "remove", "~/code"]) end)
          end
        )

      assert {:error, :disabled, _} = result
      assert Enum.map(configured(), & &1["name"]) == ["legacy"]
      assert config!() != before
      assert decoded()["repos"]["allowed_roots"] == []
    end

    test "a root removed after listing is root_not_allowed, or disabled without others",
         %{home: home, code: code} do
      repo!(Path.join(code, "app"))
      srv = dir!(Path.join(home, "srv"))
      allow!(["~/code", srv])

      remove_root = fn ->
        with_io(fn -> 0 = CLI.run(["repos", "roots", "remove", "~/code"]) end)
      end

      assert {:error, :root_not_allowed, _} = register([], before_lock: remove_root)
      refute Map.has_key?(decoded(), "local_repositories")

      allow!(["~/code"])
      assert {:error, :disabled, _} = register([], before_lock: remove_root)
      refute Map.has_key?(decoded(), "local_repositories")
    end

    test "a name already configured is name_taken", %{code: code} do
      add_entry("app", repo!(Path.join(code, "app")))
      repo!(Path.join(code, "app2"))
      assert code(path: "app2", name: "app") == :name_taken
    end

    test "removing a CLI entry outside every root keeps the repository", %{home: home} do
      legacy = repo!(Path.join(home, "elsewhere/legacy"))
      snapshot = HelmsmanDaemon.LocalRepoHelpers.snapshot(legacy)
      add_entry("legacy", legacy)
      add_entry("other", legacy <> "-other")

      assert LocalRepos.remove_from_web(remove_push("legacy")) == :ok
      assert Enum.map(configured(), & &1["name"]) == ["other"]
      assert HelmsmanDaemon.LocalRepoHelpers.snapshot(legacy) == snapshot
    end

    test "removing a name that is not configured is not_configured" do
      before = config!()
      assert {:error, :not_configured, _} = LocalRepos.remove_from_web(remove_push("ghost"))
      assert config!() == before
    end
  end

  describe "every error code" do
    test "disabled" do
      allow!([])
      assert code([]) == :disabled
      write_config!("broken = [")
      assert code([]) == :disabled
      assert {:error, :disabled, _} = LocalRepos.remove_from_web(remove_push("app"))
    end

    test "root_not_allowed", %{code: code} do
      repo!(Path.join(code, "app"))
      assert code(root: "~/other") == :root_not_allowed
      assert code(root: code) == :root_not_allowed
    end

    test "invalid_path, including more than 4 levels", %{code: code} do
      repo!(Path.join(code, "a/b/c/d/e"))

      for path <- ["a/b/c/d/e", "/etc", "a//b", "a/./b", "a/", ""],
          do: assert(code(path: path) == :invalid_path, inspect(path))
    end

    test "missing", %{code: code} do
      File.write!(Path.join(code, "file"), "x")
      assert code(path: "nope") == :missing
      assert code(path: "file") == :missing
      assert code(path: "file/x") == :missing
    end

    test "outside_root for a .git link and a submodule whose git data is outside",
         %{home: home, code: code} do
      real = repo!(Path.join(home, "secret/real"))
      dir = dir!(Path.join(code, "gitlink"))
      link!(Path.join(real, ".git"), Path.join(dir, ".git"))
      assert code(path: "gitlink", name: "gitlink") == :outside_root

      source = repo!(Path.join(home, "source"))
      sup = repo!(Path.join(home, "sup"))

      git!(sup, [
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        "-q",
        source,
        "libs/mod"
      ])

      allow!(["~/code", Path.join(sup, "libs")])
      assert code(root: Path.join(sup, "libs"), path: "mod", name: "mod") == :outside_root
    end

    test "not_a_repository, with dubious ownership", %{home: home, code: code} do
      dir!(Path.join(code, "notes"))
      assert {:error, :not_a_repository, "not a git repository"} = register(path: "notes")

      repo!(Path.join(code, "app"))
      dir!(Path.join(code, "app/src"))
      assert code(path: "app/src") == :not_a_repository

      git = logging_git(home, "export GIT_TEST_ASSUME_DIFFERENT_OWNER=1\n")

      assert {:error, :not_a_repository, message} =
               unchanged(fn -> register([], executable: git.executable) end)

      assert message =~ "dubious ownership"
    end

    test "inside_daemon_home", %{home: home} do
      allow!(["~"])
      user_repo(Path.join(Paths.home(), "repos"), "app")
      assert code(root: "~", path: ".helmsman/repos/app") == :inside_daemon_home
      assert home != Paths.home()
    end

    test "invalid_name", %{code: code} do
      repo!(Path.join(code, "app"))

      for name <- ["App", "-x", "", String.duplicate("a", 65)],
          do: assert(code(name: name) == :invalid_name)
    end

    test "invalid_workspaces", %{code: code} do
      repo!(Path.join(code, "app"))

      for ids <- [[], [7, 7], [8], [7, 8]],
          do: assert(code(workspaces: ids) == :invalid_workspaces, inspect(ids))

      File.rm!(LocalRepos.served_path())
      assert code(workspaces: [7]) == :invalid_workspaces
      served([{7, "acme"}, {9, "beta"}])
      assert register(workspaces: [9, 7]) == :ok
    end

    test "already_registered names the existing entry", %{home: home, code: code} do
      app = repo!(Path.join(code, "app"))
      link!(app, Path.join(home, "alias"))
      add_entry("legacy", Path.join(home, "alias"))

      assert {:error, :already_registered, "already registered as legacy"} =
               unchanged(fn -> register(name: "app") end)
    end

    test "config_error when the file cannot be written or rewritten safely", %{code: code} do
      repo!(Path.join(code, "app"))

      assert {:error, :config_error, "could not write " <> _} =
               unchanged(fn -> register([], before_rename: fn -> raise "disk full" end) end)

      write_config!(
        config!() <>
          "\n[[local_repositories]]\nname = \"x\"\npath = \"/x\"\nworkspaces = [7]\nwhen = 1979-05-27\n"
      )

      assert {:error, :config_error, message} = unchanged(fn -> register([]) end)
      assert message =~ "cannot edit safely"
    end
  end

  describe "the configuration" do
    test "repos list marks web entries; repos add / remove keep their keys", %{code: code} do
      repo!(Path.join(code, "app"))
      other = repo!(Path.join(code, "other"))
      assert register([], now: fn -> ~U[2026-10-14 06:40:00Z] end) == :ok
      web = hd(configured())

      {0, output} = with_io(fn -> CLI.run(["repos", "list"]) end)
      assert output =~ ~r/^app\t.*\tavailable \(added from the web\)$/m

      {0, _} =
        with_io(fn ->
          CLI.run(["repos", "add", other, "--name", "other", "--workspace", "acme"])
        end)

      assert [^web, %{"name" => "other"}] = configured()
      {0, output} = with_io(fn -> CLI.run(["repos", "list"]) end)
      refute output =~ ~r/^other.*added from the web/m

      {0, _} = with_io(fn -> CLI.run(["repos", "remove", "other"]) end)
      assert configured() == [web]
    end

    test "concurrent web registration and repos add both land", %{code: code} do
      repo!(Path.join(code, "app"))
      web_dir = repo!(Path.join(code, "web"))
      test = self()

      web =
        Task.async(fn ->
          register([],
            before_rename: fn ->
              send(test, :web_holding)
              receive do: (:go -> :ok)
            end
          )
        end)

      assert_receive :web_holding, 5_000
      cli = Task.async(fn -> LocalRepos.add(web_dir, "web", ["acme"]) end)
      refute Task.yield(cli, 300)
      send(web.pid, :go)
      assert Task.await(web) == :ok
      assert Task.await(cli, 15_000) == :ok
      assert Enum.map(configured(), & &1["name"]) == ["app", "web"]
    end

    test "a lock kept longer than the wait is busy and changes nothing", %{code: code} do
      repo!(Path.join(code, "app"))
      holder = hold_lock()
      assert {:error, :busy, _} = unchanged(fn -> register([], lock_timeout_ms: 200) end)

      assert {:error, :busy, _} =
               unchanged(fn ->
                 LocalRepos.remove_from_web(remove_push("x"), lock_timeout_ms: 200)
               end)

      send(holder, :release)
      assert ConfigLock.timeout_ms() == 10_000
    end

    test "killing the task while it holds the lock frees the lock; the file is old or new",
         %{code: code} do
      repo!(Path.join(code, "app"))
      before = config!()
      test = self()

      {:ok, pid} =
        Task.start(fn ->
          register([],
            before_rename: fn ->
              send(test, :holding)
              Process.sleep(:infinity)
            end
          )
        end)

      assert_receive :holding, 5_000
      Process.exit(pid, :kill)
      started = System.monotonic_time(:millisecond)
      assert ConfigLock.with_lock(fn -> :locked end, timeout_ms: 2_000) == {:ok, :locked}
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert config!() == before
      assert {:ok, _} = Toml.decode(config!())
    end
  end

  describe "checks inside the lock" do
    test "removing the root entry while waiting gives root_not_allowed or disabled",
         %{code: code} do
      repo!(Path.join(code, "app"))
      assert {:error, code, _} = register([], before_lock: fn -> allow!([]) end)
      assert code in [:disabled, :root_not_allowed]
      refute Map.has_key?(decoded(), "local_repositories")
    end

    test "every check runs between taking and releasing the lock", %{code: code} do
      repo!(Path.join(code, "app"))
      test = self()

      result =
        register([],
          lock: RecordingLock,
          before_lock: fn -> send(test, :before_lock) end,
          trace: fn step -> send(test, {:step, step}) end
        )

      assert result == :ok

      assert messages() ==
               [:before_lock, :lock_acquired] ++
                 Enum.map(
                   ~w(read_config roots path walk dot_git check git_dirs name workspaces configured write)a,
                   &{:step, &1}
                 ) ++ [:lock_released]

      LocalRepos.remove_from_web(remove_push("app"),
        lock: RecordingLock,
        before_lock: fn -> send(test, :before_lock) end,
        trace: fn step -> send(test, {:step, step}) end
      )

      assert messages() ==
               [:before_lock, :lock_acquired, {:step, :read_config}, {:step, :roots}] ++
                 [{:step, :configured}, {:step, :write}, :lock_released]
    end
  end

  defp messages do
    receive do
      message when message in [:before_lock, :lock_acquired, :lock_released] ->
        [message | messages()]

      {:step, _} = message ->
        [message | messages()]
    after
      0 -> []
    end
  end

  defp hold_lock do
    test = self()

    pid =
      spawn_link(fn ->
        ConfigLock.with_lock(fn ->
          send(test, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held, 5_000
    pid
  end
end

defmodule HelmsmanDaemon.LocalReposBrowseTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import HelmsmanDaemon.WebRepoHelpers
  alias HelmsmanDaemon.LocalRepos

  setup do
    home = web_home()
    code = dir!(Path.join(home, "code"))
    allow!(["~/code"])
    %{home: home, code: code}
  end

  defp browse(opts \\ []) do
    assert {:ok, result} = LocalRepos.browse(opts)
    result
  end

  defp paths(result), do: Enum.map(result.repositories, & &1.path)

  defp register_entries(entries) do
    blocks =
      Enum.map_join(entries, "\n", fn {name, path} ->
        "[[local_repositories]]\nname = #{inspect(name)}\npath = #{inspect(path)}\nworkspaces = [7]\n"
      end)

    write_config!(config!() <> "\n" <> blocks)
  end

  describe "scenarios" do
    test "lists app and group/lib with suggested names, not a plain directory", %{code: code} do
      repo!(Path.join(code, "app"))
      repo!(Path.join(code, "group/lib"))
      dir!(Path.join(code, "notes"))

      assert browse() == %{
               roots: ["~/code"],
               repositories: [
                 %{root: "~/code", path: "app", name: "app", registered_as: nil},
                 %{root: "~/code", path: "group/lib", name: "lib", registered_as: nil}
               ],
               truncated: false
             }
    end

    test "symbolic links are neither followed nor listed", %{home: home, code: code} do
      repo!(Path.join(home, "secret/repo"))
      link!(Path.join(home, "secret"), Path.join(code, "private"))
      link!(Path.join(home, "secret/repo"), Path.join(code, "linked"))
      repo!(Path.join(code, "app"))
      assert paths(browse()) == ["app"]
    end

    test "a repository is not entered", %{code: code} do
      repo!(Path.join(code, "app"))
      repo!(Path.join(code, "app/vendor/dep"))
      assert paths(browse()) == ["app"]
    end

    test "depth and count limits", %{code: code} do
      repo!(Path.join(code, "a/b/c/d/e"))
      for i <- 1..250, do: bare!(Path.join(code, "r#{String.pad_leading("#{i}", 3, "0")}"))

      result = browse()
      refute "a/b/c/d/e" in paths(result)
      assert length(result.repositories) == 200
      assert result.truncated
    end

    test "registered repositories carry their name; another app is suggested app-2",
         %{code: code} do
      app = repo!(Path.join(code, "app"))
      repo!(Path.join(code, "old/app"))
      register_entries([{"app", app}])

      assert browse().repositories == [
               %{root: "~/code", path: "app", name: "app", registered_as: "app"},
               %{root: "~/code", path: "old/app", name: "app-2", registered_as: nil}
             ]
    end

    test "hidden directories are skipped", %{code: code} do
      repo!(Path.join(code, ".cache/x"))
      assert paths(browse()) == []
    end
  end

  test "without a valid root the request is disabled" do
    allow!([])
    assert LocalRepos.browse() == {:error, :disabled}
    write_config!("not = [toml")
    assert LocalRepos.browse() == {:error, :disabled}
  end

  test "the fourth level is listed but not entered", %{code: code} do
    repo!(Path.join(code, "a/b/c/d"))
    repo!(Path.join(code, "w/x/y/z/deeper"))
    assert paths(browse()) == ["a/b/c/d"]
  end

  test "bare repositories are recognized; links inside a bare layout are not", %{code: code} do
    bare!(Path.join(code, "mirror.git"))
    fake = dir!(Path.join(code, "fake"))
    File.write!(Path.join(fake, "HEAD"), "ref: refs/heads/main\n")
    dir!(Path.join(fake, "refs"))
    link!(Path.join(code, "mirror.git/objects"), Path.join(fake, "objects"))

    assert browse().repositories == [
             %{root: "~/code", path: "mirror.git", name: "mirror-git", registered_as: nil}
           ]
  end

  test "a .git that is a symbolic link does not make a candidate", %{code: code} do
    repo = repo!(Path.join(code, "real"))
    dir = dir!(Path.join(code, "linkgit"))
    link!(Path.join(repo, ".git"), Path.join(dir, ".git"))
    assert paths(browse()) == ["real"]
  end

  test "a root that is itself a repository is listed as .", %{home: home, code: code} do
    repo!(Path.join(home, "My Project"))
    repo!(Path.join(code, "app"))
    allow!(["~/My Project", "~/code"])

    assert browse() == %{
             roots: ["~/My Project", "~/code"],
             repositories: [
               %{root: "~/My Project", path: ".", name: "my-project", registered_as: nil},
               %{root: "~/code", path: "app", name: "app", registered_as: nil}
             ],
             truncated: false
           }
  end

  test "suggested names are normalized and unique within 64 characters", %{code: code} do
    long = String.duplicate("x", 70)

    for dir <- ["a/My Repo", "b/My Repo", "c/_Lead", "d/Ünï", "e/+++", "f/#{long}", "g/#{long}"],
        do: repo!(Path.join(code, dir))

    register_entries([{"lead", "/nonexistent/lead"}])

    names = Map.new(browse().repositories, &{&1.path, &1.name})
    x64 = String.duplicate("x", 64)

    assert names == %{
             "a/My Repo" => "my-repo",
             "b/My Repo" => "my-repo-2",
             "c/_Lead" => "lead-2",
             "d/Ünï" => "n-",
             "e/+++" => "repo",
             "f/#{long}" => x64,
             "g/#{long}" => String.duplicate("x", 62) <> "-2"
           }

    assert Enum.all?(Map.values(names), &LocalRepos.valid_name?/1)
  end

  test "names that are not UTF-8 or contain control characters are skipped", %{code: code} do
    repo!(Path.join(code, "app"))
    bad = Path.join(code, <<"bad", 0xFF>>)
    File.mkdir_p!(Path.join(bad, ".git"))
    File.mkdir_p!(Path.join(code, "ctl\x01/.git"))
    assert paths(browse()) == ["app"]
  end

  test "unreadable directories are skipped without an error", %{code: code} do
    repo!(Path.join(code, "app"))
    locked = dir!(Path.join(code, "locked"))
    repo!(Path.join(locked, "hidden"))
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o700) end)
    assert paths(browse()) == ["app"]
  end

  test "the time and directory budgets truncate the scan", %{code: code} do
    for i <- 1..10, do: repo!(Path.join(code, "r#{i}"))

    result = browse(browse_time_limit_ms: 50, browse_on_visit: fn -> Process.sleep(15) end)
    assert result.truncated
    assert length(result.repositories) < 10

    result = browse(browse_max_dirs: 3)
    assert result.truncated
    assert length(result.repositories) == 2

    refute browse().truncated
  end

  test "a root full of plain files stops at the time budget, without hooks", %{code: code} do
    for i <- 1..20_000, do: File.write!(Path.join(code, "f#{i}"), "")
    repo!(Path.join(code, "zzz"))

    started = System.monotonic_time(:millisecond)
    result = browse(browse_time_limit_ms: 30)
    elapsed = System.monotonic_time(:millisecond) - started

    assert result.truncated
    assert result.roots == ["~/code"]
    assert elapsed < 1_000
    refute browse().truncated
  end

  test "a blocked listing ends at the deadline with the candidates found so far",
       %{home: home, code: code} do
    repo!(Path.join(code, "group/a"))
    srv = dir!(Path.join(home, "srv"))
    repo!(Path.join(srv, "b"))
    allow!(["~/code", "~/srv"])
    test = self()

    block = fn dir ->
      if dir == srv do
        send(test, {:blocked, self()})
        Process.sleep(:infinity)
      end
    end

    started = System.monotonic_time(:millisecond)
    result = browse(browse_time_limit_ms: 300, browse_on_list: block)
    elapsed = System.monotonic_time(:millisecond) - started

    assert_receive {:blocked, worker}
    refute Process.alive?(worker)
    assert elapsed in 250..2_000

    assert result == %{
             roots: ["~/code", "~/srv"],
             repositories: [%{root: "~/code", path: "group/a", name: "a", registered_as: nil}],
             truncated: true
           }
  end

  test "a budget spent before the roots are resolved answers busy" do
    block = fn -> Process.sleep(:infinity) end
    assert LocalRepos.browse(browse_time_limit_ms: 100, browse_on_start: block) == {:error, :busy}
  end

  test "the scan runs no git command", %{home: home, code: code} do
    repo!(Path.join(code, "app"))
    git = logging_git(home)
    assert paths(browse(executable: git.executable)) == ["app"]
    refute File.exists?(git.log)
  end

  test "candidates carry exactly root, path, name and registered_as", %{code: code} do
    repo!(Path.join(code, "app"))

    for item <- browse().repositories,
        do: assert(Enum.sort(Map.keys(item)) == [:name, :path, :registered_as, :root])
  end

  test "all roots share the limits, in configuration order", %{home: home, code: code} do
    srv = dir!(Path.join(home, "srv"))
    repo!(Path.join(srv, "a"))
    repo!(Path.join(code, "z"))
    allow!(["~/srv", "~/code"])

    assert Enum.map(browse().repositories, &{&1.root, &1.path}) == [
             {"~/srv", "a"},
             {"~/code", "z"}
           ]

    result = browse(browse_max_candidates: 1)
    assert result.truncated
    assert Enum.map(result.repositories, & &1.path) == ["a"]
  end
end

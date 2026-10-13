defmodule HelmsmanDaemon.Adapters.CodexProjectConfigTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex

  setup %{tmp_dir: dir} do
    HelmsmanDaemon.CodexLogin.install(dir)
    :ok
  end

  test "start and resume trust only this cwd through thread config in either home mode", %{
    tmp_dir: dir
  } do
    cwd = Path.join(dir, "repo with . and \"quotes\"")
    File.mkdir_p!(Path.join(cwd, ".git"))
    home = System.fetch_env!("CODEX_HOME")
    config = Path.join(home, "config.toml")

    File.write!(
      config,
      "# preserve user configuration\n[projects.\"/other\"]\ntrust_level = \"untrusted\"\n"
    )

    before = {File.read!(config), File.stat!(config).mtime}

    for mode <- [:user, :private], session <- [nil, "session-1"] do
      daemon_config = if mode == :private, do: "[codex]\nhome = #{JSON.encode!(home)}\n", else: ""
      File.write!(Path.join(dir, "config.toml"), daemon_config)
      run = %{spec(1) | resume_session_id: session}
      assert {:ok, launch} = Codex.prepare(run, dir, cwd)
      request = launch.stdin |> List.last() |> JSON.decode!()
      assert request["method"] == if(session, do: "thread/resume", else: "thread/start")
      assert request["params"]["cwd"] == cwd

      assert request["params"]["config"]["projects"] == %{
               cwd => %{"trust_level" => "trusted"}
             }

      refute Enum.any?(launch.argv, &String.contains?(&1, "projects"))
      assert {File.read!(config), File.stat!(config).mtime} == before
    end
  end

  test "rejects config in cwd, git root and worktree root but excludes parents above root", %{
    tmp_dir: dir
  } do
    repo = Path.join(dir, "repo")
    cwd = Path.join(repo, "sub")
    File.mkdir_p!(cwd)

    for kind <- [:directory, :file] do
      git = Path.join(repo, ".git")
      File.rm_rf!(git)
      if kind == :directory, do: File.mkdir!(git), else: File.write!(git, "gitdir: /unused")

      for location <- [repo, cwd] do
        config = Path.join([location, ".codex", "config.toml"])
        File.mkdir_p!(Path.dirname(config))
        File.write!(config, "")
        assert {:error, {:workspace_prepare, error}} = Codex.prepare(spec(1), dir, cwd)
        assert error =~ "config.toml"
        File.rm!(config)
      end

      parent_config = Path.join([dir, ".codex", "config.toml"])
      File.mkdir_p!(Path.dirname(parent_config))
      File.write!(parent_config, "")
      assert {:ok, _} = Codex.prepare(spec(1), dir, cwd)
      File.rm!(parent_config)
    end

    nongit = Path.join(System.tmp_dir!(), "codex-nongit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(nongit, "sub"))
    File.mkdir_p!(Path.join(nongit, ".codex"))
    on_exit(fn -> File.rm_rf!(nongit) end)
    File.write!(Path.join([nongit, ".codex", "config.toml"]), "")
    assert {:ok, _} = Codex.prepare(spec(1), dir, Path.join(nongit, "sub"))
  end
end

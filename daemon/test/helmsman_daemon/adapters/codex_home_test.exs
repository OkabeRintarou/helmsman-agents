defmodule HelmsmanDaemon.Adapters.CodexHomeTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.{Config, Home}
  import ExUnit.CaptureLog

  setup %{tmp_dir: dir} do
    HelmsmanDaemon.CodexLogin.install(dir)
    :ok
  end

  test "default user home is read only, including owner snapshots", %{tmp_dir: dir} do
    System.delete_env("CODEX_HOME")
    path = Path.join(System.fetch_env!("HOME"), ".codex")
    File.mkdir_p!(Path.join(path, "shell_snapshots"))
    File.write!(Path.join(path, "config.toml"), ~s(model_provider="ollama"))
    File.write!(Path.join(path, "auth.json"), "OWNER_AUTH")
    File.write!(Path.join(path, "shell_snapshots/mine.sh"), "OWNER_SNAPSHOT")
    before = snapshot(path)
    assert {:ok, {:user, ^path}} = Home.resolve()
    assert {:ok, launch} = Codex.prepare(spec(1), dir, dir)
    assert launch.env == [{"CODEX_HOME", path}]
    assert snapshot(path) == before
  end

  test "inherited home wins over HOME and Agent overrides cannot change it", %{tmp_dir: dir} do
    path = Config.home()
    run = spec(1)
    run = %{run | agent: %{run.agent | env: %{"CODEX_HOME" => "/wrong"}}}
    assert {:ok, {:user, ^path}} = Home.resolve()
    assert {:ok, launch} = Codex.prepare(run, dir, dir)
    assert launch.env == [{"CODEX_HOME", path}]
  end

  test "explicit private home expands tilde, creates only its directory and cleans snapshots", %{
    tmp_dir: dir
  } do
    path = Path.join(System.fetch_env!("HOME"), "private-codex")
    File.write!(Path.join(dir, "config.toml"), "[codex]\nhome=\"~/private-codex\"")
    assert {:ok, {:private, ^path}} = Home.resolve()
    assert {:ok, launch} = Codex.prepare(spec(1), dir, dir)
    assert launch.env == [{"CODEX_HOME", path}]
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
    File.mkdir_p!(Path.join(path, "shell_snapshots"))
    File.write!(Path.join(path, "shell_snapshots/old.sh"), "OLD")
    assert {:ok, _} = Codex.prepare(spec(1), dir, dir)
    refute File.exists?(Path.join(path, "shell_snapshots"))
  end

  test "bad private home, missing HOME and missing user directory fail without creating it", %{
    tmp_dir: dir
  } do
    for path <- ["", "relative", 1] do
      File.write!(Path.join(dir, "config.toml"), "[codex]\nhome=" <> JSON.encode!(path))
      assert {:error, :invalid_codex_home} = HelmsmanDaemon.Config.load()
    end

    File.rm!(Path.join(dir, "config.toml"))
    System.delete_env("CODEX_HOME")
    System.delete_env("HOME")
    assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)
    assert message =~ "HOME is not set"
    System.put_env("HOME", Path.join(dir, "missing-user"))
    assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)
    assert message =~ "does not exist"
    assert message =~ "codex login"
    refute File.exists?(Path.join(dir, "missing-user"))
  end

  test "daemon startup fixes the home for later detection and launch", %{tmp_dir: dir} do
    path = Config.home()
    start_supervised!({HelmsmanDaemon.Config, []})
    System.put_env("CODEX_HOME", Path.join(dir, "other-home"))
    File.write!(Path.join(dir, "config.toml"), "[codex]\nhome=\"#{dir}/other-private\"")
    assert {:ok, {:user, ^path}} = Home.resolve()
    assert {:ok, launch} = Codex.prepare(spec(1), dir, dir)
    assert launch.env == [{"CODEX_HOME", path}]
    refute File.exists?(Path.join(dir, "other-private"))
  end

  test "legacy private directory causes one migration hint across detector refresh" do
    File.write!(Path.join(Config.home(), "owner"), "OLD")

    output =
      capture_log(fn ->
        start_supervised!({HelmsmanDaemon.Detector, adapters: [Codex]})
        HelmsmanDaemon.Detector.refresh()
        HelmsmanDaemon.Detector.inventory()
      end)

    # Inherited CODEX_HOME currently points at the legacy path, so it remains in use.
    refute output =~ "is no longer used"
    System.delete_env("CODEX_HOME")
    File.mkdir_p!(Path.join(System.fetch_env!("HOME"), ".codex"))
    stop_supervised(HelmsmanDaemon.Detector)

    output =
      capture_log(fn ->
        start_supervised!({HelmsmanDaemon.Detector, adapters: [Codex]})
        HelmsmanDaemon.Detector.refresh()
        HelmsmanDaemon.Detector.inventory()
      end)

    assert length(Regex.scan(~r/Codex now uses/, output)) == 1
    assert output =~ "[codex] home"
    assert File.read!(Path.join(Paths.home(), "codex/owner")) == "OLD"
  end

  defp snapshot(path) do
    Path.wildcard(Path.join(path, "**/*"), match_dot: true)
    |> Map.new(fn file ->
      stat = File.stat!(file, time: :posix)
      {file, {stat.type, stat.mtime, stat.mode, if(stat.type == :regular, do: File.read!(file))}}
    end)
  end
end

defmodule HelmsmanDaemon.DevRunTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.Adapters.Codex
  alias Mix.Tasks.Helmsman.DevRun
  @moduletag :tmp_dir

  test "same task reuses scratch and removes private run files", %{tmp_dir: home} do
    previous = System.get_env("HELMSMAN_HOME")
    args = ["--provider", "claude", "--prompt", "x", "--task", "DEV-7", "--home", home]
    output = capture_io(fn -> DevRun.run(args) end)
    assert output =~ "succeeded"
    work = Path.join([home, "scratch", "dev", "DEV-7"])
    assert output =~ work
    File.write!(Path.join(work, "persist"), "yes")
    output = capture_io(fn -> DevRun.run(args ++ ["--resume", "fake-session"]) end)
    assert output =~ work
    assert File.read!(Path.join(work, "persist")) == "yes"
    assert System.get_env("HELMSMAN_HOME") == previous

    for dir <- Path.wildcard(Path.join([home, "runs", "*"])),
        do: assert(File.ls!(dir) == ["raw.log"])
  end

  test "dev_run uses the requested daemon config for a private Codex home", %{tmp_dir: dir} do
    home = Path.join(dir, "daemon")
    private = Path.join(dir, "private-codex")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), "[codex]\nhome=\"#{private}\"")
    cli = HelmsmanDaemon.CodexLogin.install(dir, "1")
    args = ["--provider", "codex", "--prompt", "x", "--home", home]
    output = capture_io(fn -> DevRun.run(args, [Codex]) end)
    assert output =~ "provider_auth"
    assert output =~ private
    assert File.read!(cli <> ".home") == private
    refute File.exists?(cli <> ".started")
    File.write!(Path.join(home, "config.toml"), "[codex]\nhome=\"relative\"")

    assert_raise Mix.Error, "Invalid daemon config.toml", fn ->
      DevRun.run(args, [Codex])
    end
  end

  test "copilot provider, model, effort and resume flags use the same private home", %{
    tmp_dir: dir
  } do
    cli = Path.join(dir, "copilot-cli")

    File.write!(
      cli,
      "#!/bin/sh\ncat > /dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"sessionId\":\"resumed\",\"exitCode\":0}'\n"
    )

    File.chmod!(cli, 0o700)
    previous = Application.get_env(:helmsman_daemon, :copilot_executable)
    Application.put_env(:helmsman_daemon, :copilot_executable, cli)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman_daemon, :copilot_executable, previous),
        else: Application.delete_env(:helmsman_daemon, :copilot_executable)
    end)

    output =
      capture_io(fn ->
        DevRun.run([
          "--provider",
          "copilot",
          "--model",
          "gpt-5-mini",
          "--effort",
          "low",
          "--prompt",
          "x",
          "--resume",
          "resumed",
          "--home",
          dir
        ])
      end)

    assert output =~ "succeeded"
    assert output =~ "resumed"
    assert File.dir?(Path.join(dir, "copilot-home"))
  end

  test "dev_run accepts Cursor, which stays off without the daemon config switch", %{
    tmp_dir: home
  } do
    args = ["--provider", "cursor", "--prompt", "x", "--home", home]
    output = capture_io(fn -> DevRun.run(args) end)
    assert output =~ "status: :failed"
    assert output =~ "[cursor] enabled = true"
  end

  test "invalid arguments fail before creating directories" do
    assert_raise Mix.Error, fn -> DevRun.run(["--provider", "claude"]) end
    assert_raise Mix.Error, fn -> DevRun.run(["--provider", "missing", "--prompt", "x"]) end
  end
end

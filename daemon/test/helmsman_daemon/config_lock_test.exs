defmodule HelmsmanDaemon.ConfigLockTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.WebRepoHelpers
  import HelmsmanDaemon.LocalRepoHelpers, only: [served: 1]
  alias HelmsmanDaemon.{CLI, ConfigLock}

  setup do
    home = web_home()
    served([{7, "acme"}])
    %{home: home}
  end

  defp repos_add(name, path, pause \\ []) do
    args =
      [
        "--erl",
        "+S 2:2 +A 1",
        "-pa",
        Application.app_dir(:helmsman_daemon, "ebin"),
        "-pa",
        Application.app_dir(:jason, "ebin"),
        "-pa",
        Application.app_dir(:toml, "ebin"),
        "test/support/config_cli.exs",
        name,
        path
      ] ++ pause

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [:binary, :exit_status, {:line, 4096}, args: args]
      )

    line(port, "starting")
    port
  end

  defp line(port, text, buffer \\ "") do
    if String.contains?(buffer, text) do
      buffer
    else
      receive do
        {^port, {:data, {:eol, chunk}}} -> line(port, text, buffer <> chunk)
        {^port, {:exit_status, status}} -> flunk("CLI exited #{status}: #{buffer}")
      after
        15_000 -> flunk("CLI did not report #{text}: #{buffer}")
      end
    end
  end

  defp done(port) do
    assert line(port, "result:") =~ "result::ok"
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  # The lock helper run directly: an independent OS process holding config.lock.
  defp hold_lock do
    helper = Application.app_dir(:helmsman_daemon, "priv/credentials_lock")

    port =
      Port.open({:spawn_executable, helper}, [:binary, :exit_status, args: [ConfigLock.path()]])

    assert_receive {^port, {:data, "locked\n"}}, 5_000
    port
  end

  test "two OS processes adding different names both write their entry", %{home: home} do
    a = repos_add("app", Path.join(home, "app"), ["pause"])
    line(a, "paused")
    b = repos_add("web", Path.join(home, "web"))
    refute_receive {^b, {:data, {:eol, "result:" <> _}}}, 300
    Port.command(a, "resume\n")
    done(a)
    done(b)

    assert Enum.map(configured(), & &1["name"]) == ["app", "web"]
    assert File.stat!(ConfigLock.path()).size == 0
    assert Bitwise.band(File.stat!(ConfigLock.path()).mode, 0o777) == 0o600
  end

  test "a lock held longer than the wait makes the CLI report it", %{home: home} do
    holder = hold_lock()
    dir!(Path.join(home, "code"))

    for args <- [
          ["repos", "add", Path.join(home, "app"), "--name", "app", "--workspace", "acme"],
          ["repos", "remove", "app"],
          ["repos", "roots", "add", "~/code"],
          ["repos", "roots", "remove", "~/code"]
        ] do
      {code, output} = with_io(fn -> CLI.run(args, config_lock_timeout_ms: 200) end)
      assert code == 1
      assert output =~ "config.toml is locked by another helmsman process; try again"
    end

    refute File.exists?(config_path())
    Port.close(holder)
    assert {0, _} = with_io(fn -> CLI.run(["repos", "roots", "add", "~/code"]) end)
    assert ConfigLock.timeout_ms() == 10_000
  end

  test "the lock is re-entrant in one process and separate from the credentials lock" do
    assert ConfigLock.with_lock(fn -> ConfigLock.with_lock(fn -> :inner end) end) ==
             {:ok, {:ok, :inner}}

    holder = hold_lock()

    assert HelmsmanDaemon.CredentialsLock.with_lock(fn -> :credentials end) == :credentials
    assert ConfigLock.with_lock(fn -> :never end, timeout_ms: 100) == {:error, :timeout}
    Port.close(holder)
  end
end

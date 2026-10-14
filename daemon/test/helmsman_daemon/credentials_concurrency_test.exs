defmodule HelmsmanDaemon.CredentialsConcurrencyTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.FileKeychain

  defp cli(mode, generation, pause \\ "") do
    args = [
      "--erl",
      "+S 2:2 +A 1",
      "-pa",
      Application.app_dir(:helmsman_daemon, "ebin"),
      "-pa",
      Application.app_dir(:jason, "ebin"),
      "test/support/credential_cli.exs",
      mode,
      to_string(generation),
      pause
    ]

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
        10_000 -> flunk("CLI did not report #{text}: #{buffer}")
      end
    end
  end

  defp done(port) do
    assert line(port, "result:") =~ "result::ok"
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  defp assert_items_referenced do
    if File.exists?(Paths.credentials()) do
      file = Paths.credentials() |> File.read!() |> Jason.decode!()

      committed = %{
        "ref" => file["token_ref"],
        "server_url" => file["server_url"],
        "daemon_id" => file["daemon_id"]
      }

      refs = [committed, file["pending"] | file["stale_refs"] || []]

      accounts =
        for %{"ref" => ref, "server_url" => url, "daemon_id" => id} <- refs,
            is_binary(ref),
            do: "#{url} #{id} #{ref}"

      assert Enum.sort(Map.keys(FileKeychain.items())) == Enum.sort(accounts)
    else
      assert FileKeychain.items() == %{}
    end
  end

  test "independent writes serialize pending through cleanup and commit the later writer" do
    a = cli("write", 1, "{:after, 1}")
    line(a, "paused")
    b = cli("write", 2)
    refute_receive {^b, {:data, _}}, 150
    Port.command(a, "resume\n")
    done(a)
    done(b)

    assert {:ok, %{token: "hmd_test_generation_2"}} =
             Credentials.read(store: :keychain, keychain: {FileKeychain, []})

    assert_items_referenced()

    assert Bitwise.band(File.stat!(Path.join(Paths.home(), "credentials.lock")).mode, 0o777) ==
             0o600
  end

  test "recovery cannot overwrite a waiting independent writer" do
    crashed = cli("write", 1, "{:after, 2}")
    line(crashed, "paused")
    {:os_pid, pid} = Port.info(crashed, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(pid)])
    assert_receive {^crashed, {:exit_status, _}}, 10_000
    recovering = cli("read", 0, "{:write, :commit}")
    line(recovering, "paused")
    writing = cli("write", 2)
    refute_receive {^writing, {:data, _}}, 150
    Port.command(recovering, "resume\n")
    assert line(recovering, "result:") =~ "#HelmsmanDaemon.Credentials<"
    assert_receive {^recovering, {:exit_status, 0}}, 10_000
    done(writing)

    assert {:ok, %{token: "hmd_test_generation_2"}} =
             Credentials.read(store: :keychain, keychain: {FileKeychain, []})

    assert_items_referenced()
  end

  test "deletion waits for independent rotation and removes every generation" do
    rotating = cli("write", 1, "{:after, 1}")
    line(rotating, "paused")
    deleting = cli("delete", 0)
    refute_receive {^deleting, {:data, _}}, 150
    Port.command(rotating, "resume\n")
    done(rotating)
    done(deleting)
    refute File.exists?(Paths.credentials())
    assert_items_referenced()
  end

  test "a killed CLI releases the kernel lock and leaves recoverable pending pointers" do
    killed = cli("write", 1, "{:after, 2}")
    line(killed, "paused")
    {:os_pid, pid} = Port.info(killed, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(pid)])
    assert_receive {^killed, {:exit_status, _}}, 10_000

    assert {:ok, %{token: "hmd_test_generation_1"}} =
             Credentials.read(store: :keychain, keychain: {FileKeychain, []})

    assert_items_referenced()
  end
end

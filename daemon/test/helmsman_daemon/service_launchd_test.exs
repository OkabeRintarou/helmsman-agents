defmodule HelmsmanDaemon.ServiceLaunchdTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.ServiceCase
  alias HelmsmanDaemon.{CLI, FakeServiceManager, LogFile}

  @label "dev.helmsman.helmsman-daemon"
  @target "gui/501/dev.helmsman.helmsman-daemon"

  setup do
    {:ok, fake} = FakeServiceManager.start_link(:launchd)
    %{fake: fake}
  end

  defp opts(fake, extra \\ []), do: service_opts(fake, :macos, extra)
  defp master(label \\ @label), do: Path.join([Paths.home(), "service", label <> ".plist"])

  defp agent(label \\ @label),
    do: Path.join([user_home(), "Library/LaunchAgents", label <> ".plist"])

  defp launchctl(fake) do
    fake
    |> FakeServiceManager.lines()
    |> Enum.filter(&String.starts_with?(&1, "launchctl"))
    |> Enum.reject(&(&1 =~ ~r/launchctl print/))
  end

  defp run(args, opts) do
    capture_io(fn -> send(self(), {:code, CLI.run(args, opts)}) end)
    |> then(fn output ->
      assert_received {:code, code}
      {code, output}
    end)
  end

  # launchd at login: loads the plists in LaunchAgents unless their label is disabled.
  defp relogin(fake) do
    agent_present? = File.exists?(agent())
    disabled? = Agent.get(fake, & &1.state.disabled)
    loaded? = agent_present? and not disabled?
    FakeServiceManager.update(fake, %{loaded: loaded?, running: loaded?})
  end

  test "install writes the master plist, copies it and enables, bootstraps, kickstarts", %{
    fake: fake
  } do
    home = default_home!()
    Credentials.write(credentials())
    assert {0, output} = run(["daemon", "start"], opts(fake, sleep: connects()))

    assert File.read!(master()) == """
           <?xml version="1.0" encoding="UTF-8"?>
           <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
           <plist version="1.0">
           <dict>
             <key>Label</key>
             <string>dev.helmsman.helmsman-daemon</string>
             <key>ProgramArguments</key>
             <array>
               <string>/opt/helmsman/bin/helmsman</string>
               <string>daemon</string>
               <string>start</string>
               <string>--foreground</string>
               <string>--service</string>
             </array>
             <key>RunAtLoad</key>
             <true/>
             <key>KeepAlive</key>
             <dict>
               <key>SuccessfulExit</key>
               <false/>
             </dict>
             <key>ThrottleInterval</key>
             <integer>5</integer>
             <key>EnvironmentVariables</key>
             <dict>
               <key>PATH</key>
               <string>/usr/local/bin:/usr/bin:/bin</string>
             </dict>
             <key>StandardOutPath</key>
             <string>#{home}/logs/launchd.log</string>
             <key>StandardErrorPath</key>
             <string>#{home}/logs/launchd.log</string>
           </dict>
           </plist>
           """

    assert File.read!(agent()) == File.read!(master())
    assert Bitwise.band(File.stat!(Path.join(home, "service")).mode, 0o777) == 0o700

    assert launchctl(fake) == [
             "launchctl enable #{@target}",
             "launchctl bootstrap gui/501 #{agent()}",
             "launchctl kickstart -k #{@target}"
           ]

    assert output =~ "Service: running (pid 777)"
    assert output =~ "Connected: yes"
  end

  test "another home uses a hashed label and passes HELMSMAN_HOME", %{fake: fake, tmp_dir: dir} do
    other = Path.join(dir, "hm2")
    System.put_env("HELMSMAN_HOME", other)
    Paths.ensure!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))

    hash = :crypto.hash(:sha256, other) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    label = "dev.helmsman.helmsman-daemon-" <> hash
    plist = File.read!(master(label))
    assert plist =~ "<key>HELMSMAN_HOME</key>\n    <string>#{other}</string>"
    assert File.exists?(agent(label))
  end

  test "stop disables, boots out and removes the LaunchAgents copy; login does not load it", %{
    fake: fake
  } do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))
    FakeServiceManager.reset_calls(fake)

    assert {0, output} = run(["daemon", "stop"], opts(fake))
    assert output =~ "will not start at login"

    assert launchctl(fake) == [
             "launchctl disable #{@target}",
             "launchctl bootout #{@target}"
           ]

    refute File.exists?(agent())
    assert File.exists?(master())

    relogin(fake)
    assert {3, output} = run(["daemon", "status"], opts(fake))
    assert output =~ "Service: stopped"

    # Even if the disabled flag were cleared, no definition is left to load.
    FakeServiceManager.update(fake, %{disabled: false})
    relogin(fake)
    assert {3, _} = run(["daemon", "status"], opts(fake))

    FakeServiceManager.reset_calls(fake)
    assert {0, _} = run(["daemon", "start"], opts(fake))
    [enable, bootstrap, kickstart] = launchctl(fake)
    assert enable == "launchctl enable #{@target}"
    assert bootstrap =~ "launchctl bootstrap gui/501"
    assert kickstart == "launchctl kickstart -k #{@target}"

    relogin(fake)
    write_status()
    assert {0, output} = run(["daemon", "status"], opts(fake))
    assert output =~ "Service: running (pid 777)"
  end

  test "restart of a loaded service boots it out before bootstrapping", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {3, output} = run(["daemon", "restart"], opts(fake))
    assert output =~ "daemon start"

    assert {0, _} = run(["daemon", "start"], opts(fake))
    FakeServiceManager.reset_calls(fake)
    assert {0, _} = run(["daemon", "restart"], opts(fake, binary: "/Users/u/.local/bin/helmsman"))

    assert launchctl(fake) == [
             "launchctl enable #{@target}",
             "launchctl bootout #{@target}",
             "launchctl bootstrap gui/501 #{agent()}",
             "launchctl kickstart -k #{@target}"
           ]

    assert File.read!(agent()) =~ "<string>/Users/u/.local/bin/helmsman</string>"
  end

  test "logout stops the service; after the next login it is not loaded", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))

    assert {0, output} =
             run(["logout"], opts(fake, req_options: [plug: {Req.Test, __MODULE__}]))

    assert output =~ "Stopping the background service"
    assert "launchctl disable #{@target}" in FakeServiceManager.lines(fake)
    refute File.exists?(agent())
    refute File.exists?(Paths.credentials())

    relogin(fake)
    refute Agent.get(fake, & &1.state.loaded)
  end

  describe "status" do
    setup %{fake: fake} do
      default_home!()
      %{opts: opts(fake)}
    end

    defp install_files do
      File.mkdir_p!(Path.dirname(master()))
      File.write!(master(), "<plist/>")
      File.mkdir_p!(Path.dirname(agent()))
      File.write!(agent(), "<plist/>")
    end

    test "not installed", %{opts: opts} do
      assert {3, output} = run(["daemon", "status"], opts)
      assert output =~ "Service: not installed"
    end

    test "stopped when unloaded without a LaunchAgents copy or with a disabled label", %{
      fake: fake,
      opts: opts
    } do
      install_files()
      File.rm!(agent())
      assert {3, output} = run(["daemon", "status"], opts)
      assert output =~ "Service: stopped"

      install_files()
      FakeServiceManager.update(fake, %{disabled: true, loaded: false, running: false})
      assert {_, output} = run(["daemon", "status"], opts)
      assert output =~ "Service: stopped"
    end

    test "running", %{fake: fake, opts: opts} do
      install_files()
      FakeServiceManager.update(fake, %{loaded: true, running: true})
      write_status(%{"running_runs" => [5]})
      assert {0, output} = run(["daemon", "status"], opts)
      assert output =~ "Service: running (pid 777)"
      assert output =~ "Running runs: 5"
    end

    test "enabled but not running", %{fake: fake, opts: opts} do
      install_files()
      FakeServiceManager.update(fake, %{loaded: true, running: false})
      assert {3, output} = run(["daemon", "status"], opts)
      assert output =~ "Service: enabled but not running"
    end
  end

  test "logs tail the rotated daemon log", %{fake: fake} do
    default_home!()
    assert {1, output} = run(["daemon", "logs"], opts(fake))
    assert output =~ "No daemon log yet"

    File.mkdir_p!(Path.dirname(LogFile.path()))
    File.write!(LogFile.path(), "line\n")
    assert {0, _} = run(["daemon", "logs", "-f", "-n", "5"], opts(fake))
    assert "tail -n 5 -F #{LogFile.path()}" in FakeServiceManager.lines(fake)
  end

  test "no GUI session: exit 3 without writing files", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    FakeServiceManager.update(fake, %{available: false})
    assert {3, output} = run(["daemon", "start"], opts(fake))
    assert output =~ "--foreground"
    refute File.exists?(master())
    refute File.exists?(agent())
  end

  test "failed bootout stays running and prevents logout even after the agent copy is removed", %{
    fake: fake
  } do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))
    FakeServiceManager.update(fake, %{fail: ["bootout"]})
    assert {1, output} = run(["daemon", "stop"], opts(fake))
    assert output =~ "injected failure"
    refute output =~ "Stopped "
    refute File.exists?(agent())
    assert Agent.get(fake, & &1.state.running)
    assert {1, output} = run(["daemon", "status"], opts(fake))
    assert output =~ "Service: running"

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :remote_logout)
      Req.Test.json(conn, %{})
    end)

    assert {1, _} = run(["logout"], opts(fake, req_options: [plug: {Req.Test, __MODULE__}]))
    assert Credentials.logged_in?()
    refute_received :remote_logout
    FakeServiceManager.update(fake, %{fail: []})
    assert {0, _} = run(["daemon", "stop"], opts(fake))
    assert {0, _} = run(["daemon", "stop"], opts(fake))
    refute Agent.get(fake, & &1.state.running)
  end

  test "unavailable manager and failed job state cannot authorize logout", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :remote_logout)
      Req.Test.json(conn, %{})
    end)

    for failure <- [%{available: false, fail: []}, %{available: true, fail: ["print #{@target}"]}] do
      FakeServiceManager.update(fake, failure)

      assert {3, output} =
               run(["logout"], opts(fake, req_options: [plug: {Req.Test, __MODULE__}]))

      assert output =~ "credentials kept"
      assert Credentials.logged_in?()
      refute_received :remote_logout
    end

    FakeServiceManager.update(fake, %{fail: ["print-disabled"], loaded: false, running: false})
    assert {3, _} = run(["logout"], opts(fake))
    assert Credentials.logged_in?()
  end

  test "restart stops when bootout fails", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = run(["daemon", "start"], opts(fake))
    FakeServiceManager.update(fake, %{fail: ["bootout"]})
    FakeServiceManager.reset_calls(fake)
    assert {1, _} = run(["daemon", "restart"], opts(fake))
    refute Enum.any?(FakeServiceManager.lines(fake), &String.contains?(&1, "bootstrap"))
  end
end

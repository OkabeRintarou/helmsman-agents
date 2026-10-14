defmodule HelmsmanDaemon.ServiceSystemdTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.ServiceCase
  alias HelmsmanDaemon.{CLI, FakeServiceManager, Service}
  alias HelmsmanDaemon.Service.Systemd

  setup do
    {:ok, fake} = FakeServiceManager.start_link(:systemd)
    %{fake: fake}
  end

  defp opts(fake, extra \\ []), do: service_opts(fake, :linux, extra)
  defp unit_path(name), do: Path.join([user_home(), ".config/systemd/user", name <> ".service"])

  defp mutations(fake) do
    fake
    |> FakeServiceManager.lines()
    |> Enum.filter(&(&1 =~ ~r/daemon-reload| enable| disable| restart/))
  end

  defp start(fake, extra \\ []) do
    capture_io(fn ->
      send(self(), {:code, CLI.run(["daemon", "start"], opts(fake, extra))})
    end)
    |> then(fn output ->
      assert_received {:code, code}
      {code, output}
    end)
  end

  test "Linux install writes the unit, enables it and reports the connection", %{fake: fake} do
    home = default_home!()
    Credentials.write(credentials())
    {code, output} = start(fake, sleep: connects())

    assert code == 0
    path = unit_path("helmsman-daemon")

    assert File.read!(path) == """
           [Unit]
           Description=Helmsman agent daemon

           [Service]
           Type=simple
           ExecStart="/opt/helmsman/bin/helmsman" daemon start --foreground --service
           Restart=on-failure
           RestartSec=5
           TimeoutStopSec=60
           KillMode=mixed
           Environment="PATH=/usr/local/bin:/usr/bin:/bin"

           [Install]
           WantedBy=default.target
           """

    refute File.read!(path) =~ "HELMSMAN_HOME"

    assert mutations(fake) == [
             "systemctl --user daemon-reload",
             "systemctl --user enable --now helmsman-daemon.service"
           ]

    assert output =~ "Service: running (pid 4242)"
    assert output =~ "Connected: yes"
    assert output =~ "Home: #{home}"
  end

  test "two homes get two services; the other one carries HELMSMAN_HOME", %{
    fake: fake,
    tmp_dir: dir
  } do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = start(fake)

    other = Path.join(dir, "srv/hm2")
    System.put_env("HELMSMAN_HOME", other)
    Paths.ensure!()
    Credentials.write(credentials())
    FakeServiceManager.update(fake, %{enabled: false, active: false})
    assert {0, _} = start(fake)

    hash = :crypto.hash(:sha256, other) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    name = "helmsman-daemon-" <> hash
    assert Service.name(other, false) == name
    assert File.exists?(unit_path("helmsman-daemon"))
    assert File.read!(unit_path(name)) =~ ~s(Environment="HELMSMAN_HOME=#{other}")
    assert "systemctl --user enable --now #{name}.service" in FakeServiceManager.lines(fake)
  end

  test "without a systemd user session nothing is written and the exit is 3", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    FakeServiceManager.update(fake, %{available: false})
    {code, output} = start(fake)

    assert code == 3
    assert output =~ "systemd user services are not available here"
    assert output =~ "--foreground"
    refute File.exists?(Path.join(user_home(), ".config/systemd"))
    assert mutations(fake) == []
  end

  test "mix runs refuse to install the service", %{fake: fake} do
    Credentials.write(credentials())
    {code, output} = start(fake, standalone?: false, binary: nil)
    assert code == 2
    assert output =~ "background service needs the installed binary; use --foreground"
    assert FakeServiceManager.calls(fake) == []
  end

  test "already running reports and exits 0 without touching the service", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    File.mkdir_p!(Path.dirname(unit_path("helmsman-daemon")))
    File.write!(unit_path("helmsman-daemon"), "[Unit]\n")
    FakeServiceManager.update(fake, %{enabled: true, active: true})
    {code, output} = start(fake)

    assert code == 0
    assert output =~ "already running"
    assert File.read!(unit_path("helmsman-daemon")) == "[Unit]\n"
    assert mutations(fake) == []
  end

  test "linger hint only when linger is off; nothing is run with sudo", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    {0, output} = start(fake)
    assert output =~ "the daemon stops when you log out"
    assert output =~ "sudo loginctl enable-linger $USER"
    assert "loginctl show-user tester --property=Linger" in FakeServiceManager.lines(fake)
    refute Enum.any?(FakeServiceManager.lines(fake), &(&1 =~ "sudo" or &1 =~ "enable-linger"))

    FakeServiceManager.update(fake, %{linger: "yes", enabled: false, active: false})
    {0, output} = start(fake)
    refute output =~ "enable-linger"
  end

  test "stop warns about running runs, disables persistently and keeps the unit", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = start(fake)
    write_status(%{"running_runs" => [17, 18]})
    FakeServiceManager.reset_calls(fake)

    output =
      capture_io(fn -> assert CLI.run(["daemon", "stop"], opts(fake)) == 0 end)

    assert output =~ "2 runs will be interrupted; the server retries them per its rules"
    assert mutations(fake) == ["systemctl --user disable --now helmsman-daemon.service"]
    assert File.exists?(unit_path("helmsman-daemon"))
    File.rm!(HelmsmanDaemon.StatusFile.path())

    # After a reboot with linger nothing starts a disabled unit: still stopped.
    status = capture_io(fn -> assert CLI.run(["daemon", "status"], opts(fake)) == 3 end)
    assert status =~ "Service: stopped (will not start at login)"
  end

  test "stop when not installed", %{fake: fake} do
    output = capture_io(fn -> assert CLI.run(["daemon", "stop"], opts(fake)) == 0 end)
    assert output =~ "not installed"
    assert mutations(fake) == []
  end

  test "restart rewrites the unit, then enables and restarts it", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())

    output = capture_io(fn -> assert CLI.run(["daemon", "restart"], opts(fake)) == 3 end)
    assert output =~ "not installed; run `helmsman daemon start`"

    assert {0, _} = start(fake)
    capture_io(fn -> CLI.run(["daemon", "stop"], opts(fake)) end)
    FakeServiceManager.reset_calls(fake)

    upgraded =
      opts(fake,
        binary: "/home/u/.local/bin/helmsman",
        path: "/new/bin:/usr/bin",
        sleep: connects(%{"version" => "0.12.0"})
      )

    output = capture_io(fn -> assert CLI.run(["daemon", "restart"], upgraded) == 0 end)
    unit = File.read!(unit_path("helmsman-daemon"))
    assert unit =~ ~s(ExecStart="/home/u/.local/bin/helmsman" daemon start --foreground --service)
    assert unit =~ ~s(Environment="PATH=/new/bin:/usr/bin")

    assert mutations(fake) == [
             "systemctl --user daemon-reload",
             "systemctl --user enable helmsman-daemon.service",
             "systemctl --user restart helmsman-daemon.service"
           ]

    assert output =~ "helmsman 0.12.0"
  end

  describe "status" do
    setup %{fake: fake} do
      default_home!()
      File.mkdir_p!(Path.dirname(unit_path("helmsman-daemon")))
      File.write!(unit_path("helmsman-daemon"), "[Unit]\n")
      %{opts: opts(fake)}
    end

    defp status(opts, args \\ []) do
      capture_io(fn ->
        send(self(), {:code, CLI.run(["daemon", "status" | args], opts)})
      end)
      |> then(fn output ->
        assert_received {:code, code}
        {code, output}
      end)
    end

    test "not installed", %{opts: opts} do
      File.rm!(unit_path("helmsman-daemon"))
      assert {3, output} = status(opts)
      assert output =~ "Service: not installed"
    end

    test "stopped", %{opts: opts} do
      assert {3, output} = status(opts)
      assert output =~ "Service: stopped"
      assert output =~ "Daemon: not running"
    end

    test "running and connected, with a run, disk usage and JSON", %{fake: fake, opts: opts} do
      FakeServiceManager.update(fake, %{enabled: true, active: true})
      write_status(%{"running_runs" => [17]})
      File.mkdir_p!(Path.join(Paths.home(), "work"))
      File.write!(Path.join(Paths.home(), "work/file"), String.duplicate("x", 4096))

      assert {0, output} = status(opts)
      assert output =~ "Service: running (pid 4242)"
      assert output =~ "Server: https://hm.example.test (daemon 42)"
      assert output =~ "Connected: yes"
      assert output =~ "Running runs: 17"
      assert output =~ ~r/work\/ \d+\.\d KB/
      assert output =~ "repos/ -"

      assert {0, json} = status(opts, ["--json"])
      decoded = Jason.decode!(json)
      assert decoded["service"]["state"] == "running"
      assert decoded["service"]["pid"] == 4242
      assert decoded["connected"] == true
      assert decoded["daemon"]["running_runs"] == [17]
      assert decoded["disk_usage"]["work"] >= 4096
      assert decoded["disk_usage"]["repos"] == nil
    end

    test "running but not connected exits 1", %{fake: fake, opts: opts} do
      FakeServiceManager.update(fake, %{enabled: true, active: true})
      write_status(%{"connected" => false, "connected_at" => nil})
      assert {1, output} = status(opts)
      assert output =~ "Connected: no"
    end

    test "enabled but not running", %{fake: fake, opts: opts} do
      FakeServiceManager.update(fake, %{enabled: true, active: false})
      assert {3, output} = status(opts)
      assert output =~ "Service: enabled but not running"
    end
  end

  test "logs reads the user journal of the unit", %{fake: fake} do
    default_home!()

    capture_io(fn ->
      assert CLI.run(["daemon", "logs"], opts(fake)) == 0
      assert CLI.run(["daemon", "logs", "-f", "-n", "20"], opts(fake)) == 0
    end)

    assert FakeServiceManager.lines(fake) == [
             "journalctl --user -u helmsman-daemon.service -o cat -n 100",
             "journalctl --user -u helmsman-daemon.service -o cat -n 20 -f"
           ]
  end

  test "logout stops an enabled service before deleting credentials", %{fake: fake} do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = start(fake)
    owner = self()

    cmd = fn program, args, cmd_opts ->
      if "disable" in args, do: send(owner, {:credentials_present, Credentials.logged_in?()})
      FakeServiceManager.cmd(fake).(program, args, cmd_opts)
    end

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))
    logout_opts = opts(fake, cmd: cmd, req_options: [plug: {Req.Test, __MODULE__}])
    output = capture_io(fn -> assert CLI.run(["logout"], logout_opts) == 0 end)

    assert output =~ "Stopping the background service before logging out"
    assert_received {:credentials_present, true}

    assert "systemctl --user disable --now helmsman-daemon.service" in FakeServiceManager.lines(
             fake
           )

    refute File.exists?(Paths.credentials())
  end

  test "unit values are quoted against specifiers and expansion" do
    ctx = %{
      name: "helmsman-daemon",
      binary: "/opt/a b/100%/$x/helmsman",
      path: "/p\"q",
      home: "/h",
      default_home?: true
    }

    unit = Systemd.unit(ctx)
    assert unit =~ ~S(ExecStart="/opt/a b/100%%/$$x/helmsman" daemon start)
    assert unit =~ ~S(Environment="PATH=/p\"q")
  end

  test "logout keeps credentials and makes no remote request when manager or state is unknown", %{
    fake: fake
  } do
    default_home!()
    Credentials.write(credentials())
    assert {0, _} = start(fake)
    before = File.read!(Paths.credentials())
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :remote_logout)
      Req.Test.json(conn, %{})
    end)

    logout_opts = opts(fake, req_options: [plug: {Req.Test, __MODULE__}])

    for failure <- [
          %{available: false, fail: []},
          %{available: true, fail: ["is-enabled"]},
          %{available: true, fail: ["is-active"]}
        ] do
      FakeServiceManager.update(fake, failure)
      output = capture_io(fn -> assert CLI.run(["logout"], logout_opts) == 3 end)
      assert output =~ "credentials kept"
      assert File.read!(Paths.credentials()) == before
      refute_received :remote_logout
    end

    refute Enum.any?(FakeServiceManager.lines(fake), &String.contains?(&1, "disable"))
  end
end

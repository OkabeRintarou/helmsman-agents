defmodule HelmsmanDaemon.EnvFileTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import HelmsmanDaemon.ServiceCase
  alias HelmsmanDaemon.{CLI, Env, EnvFile, FakeServiceManager}

  @names ~w(HM_TEST_A HM_TEST_B HM_TEST_C HM_TEST_D PATH GIT_DIR CURSOR_API_KEY COPILOT_GITHUB_TOKEN)

  setup do
    previous = Map.take(System.get_env(), @names)

    on_exit(fn ->
      Enum.each(@names, &System.delete_env/1)
      System.put_env(previous)
    end)

    Enum.each(@names -- ["PATH"], &System.delete_env/1)
    :ok
  end

  defp write_env(contents, mode \\ 0o600) do
    File.write!(EnvFile.path(), contents)
    File.chmod!(EnvFile.path(), mode)
  end

  test "parses comments, blank lines, = in values and reports lines without =" do
    assert EnvFile.parse("""
           # a comment
             # indented comment

           HM_TEST_A=one=two==
           HM_TEST_B=
           not a pair
           export HM_TEST_C=x
           HM_TEST_D=$HOME "quoted"
           """) ==
             {[{"HM_TEST_A", "one=two=="}, {"HM_TEST_B", ""}, {"HM_TEST_D", ~S($HOME "quoted")}],
              [6, 7]}
  end

  test "loads missing variables only, warns about ignored lines, never expands" do
    System.put_env("HM_TEST_B", "from service")

    write_env(
      "HM_TEST_A=a=b\nHM_TEST_B=from file\nbroken line\nHM_TEST_D=$HOME\nHELMSMAN_HOME=/x\n"
    )

    log = capture_log(fn -> assert {:ok, ["HM_TEST_A", "HM_TEST_D"]} = EnvFile.load() end)
    assert System.get_env("HM_TEST_A") == "a=b"
    assert System.get_env("HM_TEST_B") == "from service"
    assert System.get_env("HM_TEST_D") == "$HOME"
    assert System.get_env("HELMSMAN_HOME") != "/x"
    assert log =~ "daemon.env line 3 ignored"
    refute log =~ "broken line"
  end

  test "an existing PATH from the service definition wins" do
    path = System.get_env("PATH")
    write_env("PATH=/x\n")
    capture_log(fn -> EnvFile.load() end)
    assert System.get_env("PATH") == path
  end

  test "permissions wider than 0600 are not read and log a warning" do
    write_env("HM_TEST_A=secret\n", 0o644)
    log = capture_log(fn -> assert {:error, :insecure} = EnvFile.load() end)
    assert log =~ "daemon.env is not read"
    assert System.get_env("HM_TEST_A") == nil
    refute log =~ "secret"
  end

  test "values from daemon.env still go through the environment scrub" do
    write_env("GIT_DIR=/hostile\nHM_TEST_A=kept\n")
    capture_log(fn -> EnvFile.load() end)
    assert System.get_env("GIT_DIR") == "/hostile"
    capture_io(:stderr, fn -> Env.scrub_process!() end)
    assert System.get_env("GIT_DIR") == nil
    assert System.get_env("HM_TEST_A") == "kept"
    refute Map.has_key?(Env.child(), "GIT_DIR")
  end

  test "the binary launcher's variables are not passed to agents" do
    base = %{
      "__BURRITO" => "1",
      "__BURRITO_BIN_PATH" => "/b",
      "RELEASE_ROOT" => "/r",
      "RELEASE_SYS_CONFIG" => "/r/sys",
      "PATH" => "/bin"
    }

    assert Env.child(base) == %{"PATH" => "/bin"}
  end

  test "daemon start names credential variables the service will miss, never their values" do
    default_home!()
    Credentials.write(credentials())
    {:ok, fake} = FakeServiceManager.start_link(:systemd)
    System.put_env("CURSOR_API_KEY", "cursor-secret-value")
    System.put_env("COPILOT_GITHUB_TOKEN", "copilot-secret-value")
    write_env("COPILOT_GITHUB_TOKEN=copilot-secret-value\n")

    output =
      capture_io(fn ->
        assert CLI.run(["daemon", "start"], service_opts(fake, :linux)) == 0
      end)

    [hint] = output |> String.split("\n") |> Enum.filter(&(&1 =~ "does not inherit"))
    assert hint =~ "CURSOR_API_KEY"
    assert hint =~ "add them to daemon.env"
    refute hint =~ "COPILOT_GITHUB_TOKEN"
    refute output =~ "secret-value"

    files = Path.wildcard(Path.join([System.get_env("HOME"), "**", "*"]), match_dot: true)
    files = files ++ Path.wildcard(Path.join(Paths.home(), "**/*"), match_dot: true)

    for file <- files, File.regular?(file) do
      refute File.read!(file) =~ "cursor-secret-value", file
    end

    assert File.read!(EnvFile.path()) == "COPILOT_GITHUB_TOKEN=copilot-secret-value\n"
  end
end

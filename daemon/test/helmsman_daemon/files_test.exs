defmodule HelmsmanDaemon.FilesTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Config
  import ExUnit.CaptureLog

  test "stable machine id and private directory tree" do
    id = Paths.machine_id()
    assert id =~ ~r/^[a-f0-9]{32}$/
    assert Paths.machine_id() == id

    for directory <- [
          Paths.home(),
          Paths.state(),
          Path.join(Paths.home(), "runs"),
          Path.join(Paths.home(), "scratch")
        ] do
      assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
    end
  end

  test "configuration defaults and invalid concurrency" do
    assert {:ok, %{max_concurrency: 4}} = Config.load()

    for value <- [0, 33] do
      File.write!(Path.join(Paths.home(), "config.toml"), "max_concurrency = #{value}\n")
      assert {:error, :invalid_config} = Config.load()
    end
  end

  test "credential roundtrip, redaction, correction and atomic failure" do
    credentials = credentials()
    assert :ok = Credentials.write(credentials)
    assert {:ok, ^credentials} = Credentials.read()
    refute inspect(credentials) =~ credentials.token
    assert Bitwise.band(File.stat!(Paths.credentials()).mode, 0o777) == 0o600
    File.chmod!(Paths.credentials(), 0o644)
    assert capture_log(fn -> assert {:ok, ^credentials} = Credentials.read() end) =~ "0600"

    assert {:error, :write_failed} =
             Credentials.write(%{credentials | token: "hmd_new"},
               before_rename: fn -> raise "fault" end
             )

    assert {:ok, ^credentials} = Credentials.read()
    refute Path.wildcard(Paths.credentials() <> ".*.tmp") != []
  end
end

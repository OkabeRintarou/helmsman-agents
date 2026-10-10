defmodule HelmsmanDaemonTest do
  use ExUnit.Case, async: true

  test "the application starts its top-level supervisor" do
    pid = Process.whereis(HelmsmanDaemon.Supervisor)

    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "the shared protocol library is available with a positive version" do
    version = HelmsmanProtocol.version()

    assert is_integer(version)
    assert version > 0
  end
end

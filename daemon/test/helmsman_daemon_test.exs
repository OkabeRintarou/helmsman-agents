defmodule HelmsmanDaemonTest do
  use ExUnit.Case, async: true

  test "application starts erlexec without starting the daemon" do
    assert Process.whereis(HelmsmanDaemon.Supervisor) == nil
    assert Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :erlexec end)
  end

  test "shared protocol is available", do: assert(HelmsmanProtocol.version() > 0)
end

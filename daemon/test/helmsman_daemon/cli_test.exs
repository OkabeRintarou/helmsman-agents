defmodule HelmsmanDaemon.CLITest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.CLI

  test "runtimes shows detection and workspaces without tokens" do
    Credentials.write(credentials())
    output = capture_io(fn -> assert CLI.run(["runtimes"]) == 0 end)
    assert output =~ "claude: 1.0.0 available"
    assert output =~ "bos"
    refute output =~ credentials().token
  end

  test "usage and background commands exit 2" do
    for args <- [
          ["unknown"],
          ["runtimes", "--force"],
          ["daemon", "status"],
          ["daemon", "start", "--bad"]
        ] do
      capture_io(fn -> assert CLI.run(args) == 2 end)
    end
  end

  test "no adapters exits 5" do
    assert capture_io(fn -> assert CLI.run(["daemon", "start"], adapters: []) == 5 end) =~
             "Install"
  end
end

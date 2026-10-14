defmodule HelmsmanDaemon.CLIVersionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.{CLI, Release}

  @version "../../../VERSION" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  test "mix runs report the repository VERSION, the protocol and target dev" do
    output = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
    assert output == "helmsman #{@version} (protocol #{HelmsmanProtocol.version()}, dev)\n"
  end

  test "the binary reports its platform target" do
    output = capture_io(fn -> assert CLI.run(["--version"], standalone?: true) == 0 end)

    assert output =~
             ~r/^helmsman #{Regex.escape(@version)} \(protocol \d+, (linux|macos)-(x64|arm64)\)$/m

    assert Release.platform_target({:unix, :linux}, ~c"x86_64-pc-linux-musl") == "linux-x64"

    assert Release.platform_target({:unix, :linux}, ~c"aarch64-unknown-linux-gnu") ==
             "linux-arm64"

    assert Release.platform_target({:unix, :darwin}, ~c"aarch64-apple-darwin24.0.0") ==
             "macos-arm64"

    assert Release.platform_target({:unix, :darwin}, ~c"x86_64-apple-darwin23.6.0") == "macos-x64"
  end
end

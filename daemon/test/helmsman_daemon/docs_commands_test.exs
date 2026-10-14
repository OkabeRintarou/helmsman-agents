defmodule HelmsmanDaemon.DocsCommandsTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.CLI

  @docs [
    Path.expand("../../../docs/INSTALL.md", __DIR__),
    Path.expand("../../README.md", __DIR__)
  ]

  @groups ~w(daemon repos)

  # `helmsman <command>` (and `helmsman daemon|repos <command>`) as written in docs.
  defp commands(text) do
    ~r/(?<![\w.\/-])helmsman ((?:--)?[a-z][a-z-]*)(?: ([a-z][a-z-]*))?/
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, group, command] when group in @groups -> "#{group} #{command}"
      [_, command | _] -> command
    end)
    |> Enum.uniq()
  end

  test "every helmsman command in the installation docs and the README is in the CLI usage" do
    usage = CLI.usage_text()

    for path <- @docs do
      found = commands(File.read!(path))
      assert found != [], "no helmsman commands found in #{path}"

      for command <- found do
        assert usage =~ "helmsman #{command}", "#{Path.basename(path)}: helmsman #{command}"
      end
    end
  end

  test "the extraction sees subcommands and ignores names that are not commands" do
    assert commands("run `helmsman daemon logs -f` then helmsman --version; see helmsman login") ==
             ["daemon logs", "--version", "login"]

    assert commands("dev.helmsman.helmsman-daemon, ~/.local/bin/helmsman and helmsman 0.11.0") ==
             []
  end
end

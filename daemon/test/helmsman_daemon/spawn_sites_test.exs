defmodule HelmsmanDaemon.SpawnSitesTest do
  use ExUnit.Case, async: true

  test "subprocess creation stays inside the two environment-aware launchers" do
    for path <- Path.wildcard("lib/**/*.ex") do
      source = File.read!(path)
      if Path.basename(path) != "exec.ex", do: refute(source =~ ":exec.run", path)

      if Path.basename(path) != "env.ex" do
        for call <- ["System.cmd", "Port.open", ":os.cmd", ":erlang.open_port"],
            do: refute(source =~ call, "#{path}: #{call}")
      end
    end
  end
end

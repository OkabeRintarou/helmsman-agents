defmodule HelmsmanDaemon.TestServiceCmd do
  @moduledoc "Default service executor in tests: refuses service managers, runs anything else."
  @refused ~w(systemctl launchctl loginctl journalctl)

  def run(program, args, opts) do
    if program in @refused do
      raise "test reached the real #{program} #{Enum.join(args, " ")}; inject :cmd"
    else
      HelmsmanDaemon.Service.system_cmd(program, args, opts)
    end
  end
end

defmodule HelmsmanDaemon.Adapters.ClaudeReplay do
  @moduledoc "Replays recorded Claude output through the POSIX fake CLI."
  alias HelmsmanDaemon.Adapters.{Claude, Fake}
  defdelegate init_state(spec), to: Claude
  defdelegate handle_output(stream, line, state), to: Claude
  defdelegate finish(status, state), to: Claude
  defdelegate interrupt(state), to: Claude
  defdelegate steer(ref, text, state), to: Claude

  def prepare(spec, run_dir, work_dir) do
    scenario = List.first(spec.agent.custom_args)
    clean = %{spec | agent: %{spec.agent | custom_args: []}}

    with {:ok, launch} <- Claude.prepare(clean, run_dir, work_dir) do
      {:ok, %{launch | argv: [Fake.executable() | tl(launch.argv)] ++ ["--scenario", scenario]}}
    end
  end
end

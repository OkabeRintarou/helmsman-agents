defmodule HelmsmanDaemon.Adapters.CopilotReplay do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.{Copilot, Fake}
  defdelegate init_state(spec), to: Copilot
  defdelegate init_state(spec, launch), to: Copilot
  defdelegate handle_output(stream, line, state), to: Copilot
  defdelegate finish(code, state), to: Copilot
  defdelegate interrupt(state), to: Copilot
  defdelegate steer(ref, text, state), to: Copilot

  def prepare(spec, run_dir, work_dir),
    do:
      prepare(spec, run_dir, work_dir, HelmsmanDaemon.Env.agent(System.get_env(), spec.agent.env))

  def prepare(spec, run_dir, work_dir, env) do
    [scenario] = spec.agent.custom_args
    clean = %{spec | agent: %{spec.agent | custom_args: []}}

    with {:ok, launch} <- Copilot.prepare(clean, run_dir, work_dir, env) do
      {:ok, %{launch | argv: [Fake.executable() | tl(launch.argv)] ++ ["--scenario", scenario]}}
    end
  end
end

defmodule HelmsmanDaemon.Adapters.AbortFake do
  @moduledoc "Fake adapter for testing abort precedence and continued raw output."
  alias HelmsmanDaemon.Adapters.Fake

  def prepare(spec, run_dir, work_dir) do
    with {:ok, launch} <- Fake.prepare(spec, run_dir, work_dir),
         do: {:ok, %{launch | close_stdin?: false}}
  end

  defdelegate finish(code, state), to: Fake
  defdelegate steer(ref, text, state), to: Fake

  def init_state(spec),
    do: Map.put(Fake.init_state(spec), :reason, String.to_existing_atom(spec.prompt))

  def handle_output(:stdout, "abort", state),
    do:
      {[], [{:write, "must be ignored\n"}, :close_stdin, {:abort, state.reason, "stop now"}],
       state}

  def handle_output(stream, line, state), do: Fake.handle_output(stream, line, state)
  def interrupt(_state), do: {:write, "interrupt\n"}
end

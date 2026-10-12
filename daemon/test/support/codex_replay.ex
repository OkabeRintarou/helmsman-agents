defmodule HelmsmanDaemon.Adapters.CodexReplay do
  @moduledoc false
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.{Codex, Fake}
  defdelegate provider(), to: Codex
  defdelegate executable(), to: Fake
  defdelegate min_version(), to: Codex
  defdelegate detect(), to: Codex
  defdelegate max_line_bytes(), to: Codex

  def prepare(spec, run_dir, work_dir) do
    with {:ok, launch} <-
           Codex.prepare(%{spec | agent: %{spec.agent | custom_args: []}}, run_dir, work_dir) do
      {:ok, %{launch | argv: [Fake.executable(), "--scenario", hd(spec.agent.custom_args)]}}
    end
  end

  defdelegate init_state(spec), to: Codex
  defdelegate handle_output(stream, line, state), to: Codex
  defdelegate finish(code, state), to: Codex
  defdelegate interrupt(state), to: Codex
  defdelegate steer(text, state), to: Codex
end

defmodule HelmsmanDaemon.CodexFixtures do
  alias HelmsmanDaemon.Adapters.Codex
  @moduledoc false
  @root Path.expand("../fixtures/codex", __DIR__)
  def root, do: @root
  def read(name, ext \\ ".jsonl"), do: File.read!(Path.join(@root, name <> ext))

  def values(name),
    do: name |> read() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  def replay(name, spec) do
    Enum.reduce(
      String.split(read(name), "\n", trim: true),
      {[], [], Codex.init_state(spec)},
      fn line, {events, actions, state} ->
        {next, more, state} = Codex.handle_output(:stdout, line, state)
        {events ++ next, actions ++ more, state}
      end
    )
  end

  def scenario(name) do
    Enum.map_join(
      String.split(read(name, ".stderr"), "\n", trim: true),
      "",
      &("err " <> &1 <> "\n")
    ) <>
      Enum.map_join(String.split(read(name), "\n", trim: true), "", &("json " <> &1 <> "\n")) <>
      "await_stdin_eof\nexit #{String.trim(read(name, ".exit"))}\n"
  end
end

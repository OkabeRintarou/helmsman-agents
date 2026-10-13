defmodule HelmsmanDaemon.Adapters.CursorReplay do
  @moduledoc "Replays recorded Cursor output through the POSIX fake CLI."
  alias HelmsmanDaemon.Adapters.{Cursor, Fake}
  defdelegate init_state(spec, launch), to: Cursor
  defdelegate init_state(spec), to: Cursor
  defdelegate handle_output(stream, line, state), to: Cursor
  defdelegate finish(status, state), to: Cursor
  defdelegate interrupt(state), to: Cursor
  defdelegate steer(ref, text, state), to: Cursor

  def prepare(spec, run_dir, work_dir, env) do
    scenario = List.first(spec.agent.custom_args)
    clean = %{spec | agent: %{spec.agent | custom_args: []}}

    with {:ok, launch} <- Cursor.prepare(clean, run_dir, work_dir, env) do
      {:ok, %{launch | argv: [Fake.executable() | tl(launch.argv)] ++ ["--scenario", scenario]}}
    end
  end

  @doc "Fake CLI instructions for a recording; `tail` runs after its output."
  def scenario(fixtures, name, tail \\ nil) do
    read = fn ext -> File.read!(Path.join(fixtures, name <> ext)) end
    code = String.trim(read.(".exit"))

    lines = fn ext, op ->
      Enum.map_join(String.split(read.(ext), "\n", trim: true), "", &"#{op} #{&1}\n")
    end

    "await_stdin_eof\n" <>
      lines.(".jsonl", "json") <> lines.(".stderr", "err") <> (tail || "exit #{code}\n")
  end
end

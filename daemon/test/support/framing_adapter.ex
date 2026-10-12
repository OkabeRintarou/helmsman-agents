defmodule HelmsmanDaemon.Adapters.Framing do
  @moduledoc false
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.Fake
  defdelegate provider(), to: Fake
  defdelegate executable(), to: Fake
  defdelegate min_version(), to: Fake
  defdelegate detect(), to: Fake
  defdelegate prepare(spec, run_dir, work_dir), to: Fake
  defdelegate interrupt(state), to: Fake
  defdelegate steer(text, state), to: Fake
  def max_line_bytes, do: Application.get_env(:helmsman_daemon, :framing_limit, 32 * 1_048_576)
  def init_state(spec), do: spec.agent.name

  def handle_output(stream, line, owner) do
    send(
      :erlang.list_to_pid(String.to_charlist(owner)),
      {:framed, stream, byte_size(line), :crypto.hash(:sha256, line)}
    )

    {[], [], owner}
  end

  def finish(_, _), do: {:succeeded, %{session_id: nil, summary: "framed", usage: nil}}
end

defmodule HelmsmanDaemon.Adapters.FramingLauncher do
  @moduledoc false
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.Framing
  defdelegate provider(), to: Framing
  defdelegate executable(), to: Framing
  defdelegate min_version(), to: Framing
  defdelegate detect(), to: Framing
  defdelegate max_line_bytes(), to: Framing

  def prepare(_spec, _run_dir, _work_dir),
    do:
      {:ok,
       %HelmsmanDaemon.Launch{
         argv: [Application.fetch_env!(:helmsman_daemon, :framing_cli)],
         close_stdin?: true
       }}

  defdelegate init_state(spec), to: Framing
  defdelegate handle_output(stream, line, state), to: Framing
  defdelegate finish(code, state), to: Framing
  defdelegate interrupt(state), to: Framing
  defdelegate steer(text, state), to: Framing
end

defmodule HelmsmanDaemon.Adapters.Fake do
  @moduledoc "Test-only configurable POSIX fake CLI adapter."
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.{Exec, Launch}
  alias HelmsmanProtocol.Event
  def provider, do: :claude

  def executable,
    do: System.get_env("HELMSMAN_FAKE_CLI") || Path.expand("fake_cli/fake-cli", __DIR__)

  def min_version, do: Version.parse!("1.0.0")

  def detect do
    with {:ok, version} <- Exec.version(executable()),
         do: {:ok, %{version: version, models: ["fake"], efforts: []}}
  end

  def prepare(spec, _run_dir, _work_dir) do
    scenario = List.first(spec.agent.custom_args) || "success"

    scenario =
      if Path.type(scenario) == :absolute,
        do: scenario,
        else: Path.expand("fake_cli/scenarios/#{scenario}", __DIR__)

    {:ok,
     %Launch{
       argv: [executable(), "--scenario", scenario],
       stdin: spec.prompt <> "\n",
       close_stdin?: not String.ends_with?(scenario, "/echo")
     }}
  end

  def init_state(_spec), do: %{result: nil, session_id: nil, stderr: ""}

  def handle_output(stream, line, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "data" => data}} ->
        json_event(type, data, state)

      _ ->
        state = if stream == :stderr, do: %{state | stderr: line}, else: state
        actions = if String.trim(line) == "close_stdin", do: [:close_stdin], else: []
        {text_events(line), actions, state}
    end
  end

  defp json_event(type, data, state) do
    data = Map.new(data, fn {key, value} -> {String.to_existing_atom(key), value} end)

    case Enum.find(Event.types(), &(Atom.to_string(&1) == type)) do
      nil -> {text_events(Jason.encode!(data)), [], state}
      :result -> {[{:result, data}], [], %{state | result: data}}
      :session -> {[{:session, data}], [], %{state | session_id: data[:session_id]}}
      atom -> {[{atom, data}], [], state}
    end
  end

  defp text_events(line) do
    {text, _} = Event.truncate(line, 32_768)
    [{:text, %{text: text}}]
  end

  def finish(status, state) do
    result =
      cond do
        status != 0 -> {:failed, :cli_error, "CLI exit code #{status}: #{state.stderr}"}
        is_nil(state.result) -> {:failed, :unknown, "CLI exited without result"}
        state.result[:success] == false -> {:failed, :cli_error, state.result[:text]}
        true -> :succeeded
      end

    {result,
     %{session_id: state.session_id, summary: state.result && state.result[:text], usage: nil}}
  end

  def interrupt(_state), do: :signal
  def steer(_text, _state), do: :unsupported
end

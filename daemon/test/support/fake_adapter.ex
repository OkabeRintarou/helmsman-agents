defmodule HelmsmanDaemon.Adapters.Fake do
  @moduledoc """
  Test-only configurable POSIX fake CLI adapter.

  `custom_args`: the scenario, then the steering mode (`add-run-steering`
  decision 11): `unsupported` (default), `delivered` (taken once written)
  or `pending` (the fake CLI answers `steer_ok <ref>` or
  `steer_rejected <ref> <reason>`). A steering mode keeps stdin open; a
  message is written as one line `steer <ref> <text as a JSON string>`, which
  the fake CLI puts back into its result JSON as it is (`result_steered`).
  """
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
       close_stdin?: not String.ends_with?(scenario, "/echo") and steer_mode(spec) == :unsupported
     }}
  end

  defp steer_mode(spec) do
    case Enum.at(spec.agent.custom_args, 1) do
      "delivered" -> :delivered
      "pending" -> :pending
      _other -> :unsupported
    end
  end

  def init_state(spec),
    do: %{
      result: nil,
      session_id: nil,
      stderr: "",
      steer_mode: steer_mode(spec),
      pending_steers: MapSet.new()
    }

  def handle_output(:stdout, "steer_ok " <> ref, state) do
    ref = String.to_integer(String.trim(ref))

    if MapSet.member?(state.pending_steers, ref),
      do:
        {[{:status, %{level: :info, message: "steer delivered"}}],
         [{:steer_result, ref, :delivered}],
         %{state | pending_steers: MapSet.delete(state.pending_steers, ref)}},
      else: {[], [], state}
  end

  def handle_output(:stdout, "steer_rejected " <> rest, state) do
    [ref, reason] = String.split(rest, " ", parts: 2)
    ref = String.to_integer(ref)

    if MapSet.member?(state.pending_steers, ref),
      do:
        {[{:status, %{level: :warning, message: "steer rejected: " <> reason}}],
         [{:steer_result, ref, {:rejected, reason}}],
         %{state | pending_steers: MapSet.delete(state.pending_steers, ref)}},
      else: {[], [], state}
  end

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
  def steer(_ref, _text, %{steer_mode: :unsupported}), do: :unsupported

  def steer(ref, text, %{steer_mode: mode} = state) do
    line = "steer #{ref} " <> Jason.encode!(text) <> "\n"

    case mode do
      :delivered ->
        {:ok, line, :delivered, state}

      :pending ->
        {:ok, line, :pending, %{state | pending_steers: MapSet.put(state.pending_steers, ref)}}
    end
  end
end

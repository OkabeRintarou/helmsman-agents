defmodule HelmsmanDaemon.Adapter do
  @moduledoc "Extension point for agent CLI detection, launching and stream normalization."
  alias HelmsmanDaemon.Launch
  alias HelmsmanProtocol.RunSpec
  @type action :: :close_stdin | {:write, iodata()}
  @callback provider() :: :claude | :codex | :copilot | :cursor
  @callback executable() :: String.t()
  @callback min_version() :: Version.t()
  @type detection :: %{
          required(:version) => String.t(),
          required(:models) => [String.t()],
          optional(:efforts) => [String.t()]
        }
  @callback detect() :: {:ok, detection()} | {:error, String.t()}
  @callback prepare(RunSpec.t(), Path.t(), Path.t()) ::
              {:ok, Launch.t()} | {:error, {atom(), String.t()}}
  @callback init_state(RunSpec.t()) :: term()
  @callback handle_output(:stdout | :stderr, binary(), term()) ::
              {[{atom(), map()}], [action()], term()}
  @callback finish(non_neg_integer(), term()) ::
              {:succeeded | {:failed, atom(), String.t()}, map()}
  @callback interrupt(term()) :: {:write, iodata()} | :signal
  @callback max_line_bytes() :: pos_integer()
  @optional_callbacks max_line_bytes: 0
  @callback steer(String.t(), term()) :: {:ok, iodata(), term()} | :unsupported

  @adapters Application.compile_env(:helmsman_daemon, :adapters, [])
  def registered, do: @adapters
  def find(provider), do: Enum.find(@adapters, &(&1.provider() == provider))
end

defmodule HelmsmanDaemon.Adapter do
  @moduledoc """
  Extension point for agent CLI detection, launching and stream normalization.

  Steering (`add-run-steering` decision 11): `steer/3` encodes a message
  for the running CLI under the caller's reference `ref` (the feedback
  ID). `:delivered` means the CLI has taken it once the bytes are
  written; `:pending` means a later `{:steer_result, ref, result}` action
  of `handle_output/3` says so (`:delivered`) or not (`{:rejected,
  reason}`, together with a warning `status` event of the adapter's own).
  `:unsupported` when the CLI cannot take input now or at all.
  """
  alias HelmsmanDaemon.Launch
  alias HelmsmanProtocol.RunSpec

  @type daemon_failure ::
          :timeout
          | :stalled
          | :provider_network
          | :provider_rate_limit
          | :provider_auth
          | :provider_quota
          | :cli_missing
          | :cli_version
          | :workspace_prepare
          | :push_conflict
          | :push_failed
          | :context_overflow
          | :cli_error
          | :unknown
  @type steer_result :: :delivered | {:rejected, String.t()}
  @type action ::
          :close_stdin
          | {:write, iodata()}
          | {:abort, daemon_failure(), String.t()}
          | {:steer_result, term(), steer_result()}
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
  @callback prepare(RunSpec.t(), Path.t(), Path.t(), map()) ::
              {:ok, Launch.t()} | {:error, {atom(), String.t()}}
  @optional_callbacks prepare: 4
  @callback init_state(RunSpec.t()) :: term()
  @callback init_state(RunSpec.t(), Launch.t()) :: term()
  @optional_callbacks init_state: 2
  @callback handle_output(:stdout | :stderr, binary(), term()) ::
              {[{atom(), map()}], [action()], term()}
  @callback finish(non_neg_integer(), term()) ::
              {:succeeded | {:failed, atom(), String.t()}, map()}
  @callback interrupt(term()) :: {:write, iodata()} | :signal
  @callback max_line_bytes() :: pos_integer()
  @optional_callbacks max_line_bytes: 0
  @doc "Whether runs follow descendants that leave the process group (Linux only)."
  @callback track_descendants?() :: boolean()
  @optional_callbacks track_descendants?: 0
  @callback steer(ref :: term(), text :: String.t(), state :: term()) ::
              {:ok, iodata(), :delivered | :pending, term()} | :unsupported

  @adapters Application.compile_env(:helmsman_daemon, :adapters, [])
  def registered, do: @adapters
  def find(provider), do: Enum.find(@adapters, &(&1.provider() == provider))
end

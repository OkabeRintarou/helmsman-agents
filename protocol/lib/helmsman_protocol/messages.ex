defmodule HelmsmanProtocol.Messages do
  @moduledoc "Message directory and version-aware dispatch for Channel payloads."
  alias HelmsmanProtocol.{ErrorReply, Push, Reply, Report, Schema}

  @reports [
    {"join", Report.Join},
    {"sync", Report.Sync},
    {"claim", Report.Claim},
    {"starting", Report.Starting},
    {"started", Report.Started},
    {"events", Report.Events},
    {"heartbeat", Report.Heartbeat},
    {"steer_ack", Report.SteerAck},
    {"git_token", Report.GitToken},
    {"pushed", Report.Pushed},
    {"finished", Report.Finished},
    {"rotate_token", Report.RotateToken}
  ]
  @pushes [
    {"runs_available", Push.RunsAvailable},
    {"cancel", Push.Cancel},
    {"steer", Push.Steer},
    {"config_changed", Push.ConfigChanged},
    {"revoked", Push.Revoked}
  ]
  @replies %{
    "join" => Reply.Join,
    "sync" => Reply.Join,
    "claim" => Reply.Claim,
    "starting" => Reply.Starting,
    "started" => Reply.Empty,
    "events" => Reply.Events,
    "heartbeat" => Reply.Heartbeat,
    "steer_ack" => Reply.Empty,
    "git_token" => Reply.GitToken,
    "pushed" => Reply.Empty,
    "finished" => Reply.Empty,
    "rotate_token" => Reply.RotateToken
  }
  @messages Map.new(@reports ++ @pushes)
  @names Map.new(@reports ++ @pushes, fn {name, module} -> {module, name} end)

  @spec daemon_to_server() :: [String.t()]
  def daemon_to_server, do: Enum.map(@reports, &elem(&1, 0))
  @spec server_to_daemon() :: [String.t()]
  def server_to_daemon, do: Enum.map(@pushes, &elem(&1, 0))

  @spec decode(String.t(), map()) :: {:ok, struct()} | {:error, Schema.error()}
  def decode(name, payload), do: decode_module(@messages, name, payload)

  @spec decode_reply(String.t(), map()) :: {:ok, struct()} | {:error, Schema.error()}
  def decode_reply(name, payload), do: decode_module(@replies, name, payload)

  @spec reply_module(String.t()) :: {:ok, module()} | {:error, Schema.error()}
  def reply_module(name) do
    case Map.fetch(@replies, name) do
      {:ok, module} -> {:ok, module}
      :error -> Schema.invalid(["message"], {:enum, daemon_to_server()})
    end
  end

  @spec encode_reply(String.t(), struct(), integer()) :: {:ok, map()} | {:error, term()}
  def encode_reply(name, reply, target_version \\ HelmsmanProtocol.version()) do
    if HelmsmanProtocol.compatible?(target_version) do
      with {:ok, module} <- reply_module(name) do
        encode_reply_payload(module, reply, target_version)
      end
    else
      {:error, {:not_in_version, target_version}}
    end
  end

  defp encode_reply_payload(expected, %{__struct__: module} = reply, target_version)
       when module == expected or module == ErrorReply do
    with {:ok, validated} <- module.new(Map.from_struct(reply)) do
      encode_versioned(validated, target_version)
    end
  end

  defp encode_reply_payload(_, _, _), do: Schema.invalid([], :not_allowed)

  @spec encode(struct(), integer()) :: {:ok, {String.t(), map()}} | {:error, term()}
  def encode(value, target_version \\ HelmsmanProtocol.version()) do
    if HelmsmanProtocol.compatible?(target_version) do
      encode_message(value, target_version)
    else
      {:error, {:not_in_version, target_version}}
    end
  end

  defp encode_message(%{__struct__: module} = value, target_version) do
    with {:ok, name} <- Map.fetch(@names, module),
         {:ok, validated} <- module.new(Map.from_struct(value)),
         {:ok, wire} <- encode_versioned(validated, target_version) do
      {:ok, {name, wire}}
    else
      :error -> Schema.invalid(["message"], :not_allowed)
      error -> error
    end
  end

  defp encode_message(_, _), do: Schema.invalid([], :type)

  defp encode_versioned(%Reply.Claim{} = reply, target_version) do
    wire = Reply.Claim.to_wire(reply)
    runs = wire["runs"]

    if target_version < HelmsmanProtocol.provider_account_version() do
      with {:ok, encoded} <- encode_runs(runs, target_version) do
        {:ok, Map.put(wire, "runs", encoded)}
      end
    else
      {:ok, wire}
    end
  end

  defp encode_versioned(%{__struct__: module} = value, _target_version),
    do: {:ok, module.to_wire(value)}

  defp encode_runs(runs, version) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      case encode_run(run, version) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_run(%{"agent" => %{"provider_account" => nil}} = run, _version),
    do: {:ok, update_in(run, ["agent"], &Map.delete(&1, "provider_account"))}

  defp encode_run(_run, version), do: {:error, {:not_in_version, version}}

  defp decode_module(directory, name, payload) do
    case Map.fetch(directory, name) do
      {:ok, module} -> module.from_wire(payload)
      :error -> Schema.invalid(["message"], {:enum, daemon_to_server() ++ server_to_daemon()})
    end
  end
end

defmodule HelmsmanProtocol.FailureReason do
  @moduledoc "Failure reasons, split by the authority that may report them."
  @daemon ~w(timeout stalled provider_network provider_rate_limit provider_auth provider_quota cli_missing
    cli_version workspace_prepare push_conflict push_failed context_overflow cli_error unknown)a
  @server ~w(runtime_offline daemon_restart lease_expired obsolete unauthorized)a
  @spec all() :: [atom()]
  def all, do: @daemon ++ @server
  @spec daemon_reportable() :: [atom()]
  def daemon_reportable, do: @daemon
  @spec server_only() :: [atom()]
  def server_only, do: @server
end

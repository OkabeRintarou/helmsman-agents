defmodule HelmsmanProtocol do
  @moduledoc """
  Wire protocol shared by the Helmsman server and the Helmsman daemon.
  """

  @version 2
  @providers ~w(claude codex copilot cursor)a

  @doc """
  Returns the protocol version spoken by this build.

  Server and daemon compare this number during the handshake.

  ## Examples

      iex> HelmsmanProtocol.version()
      2

  """
  @spec version() :: pos_integer()
  def version, do: @version
  @doc "Protocol version that introduced provider accounts."
  @spec provider_account_version() :: pos_integer()
  def provider_account_version, do: 2

  @doc "Returns the oldest protocol version accepted by this build."
  @spec min_version() :: pos_integer()
  def min_version, do: 1

  @doc """
  Checks the version range negotiated at join.

      iex> HelmsmanProtocol.compatible?(1)
      true
      iex> HelmsmanProtocol.compatible?(0)
      false
      iex> HelmsmanProtocol.compatible?(3)
      false
  """
  @spec compatible?(term()) :: boolean()
  def compatible?(version),
    do: is_integer(version) and version >= min_version() and version <= @version

  @doc "Socket mount path; append /websocket when constructing the WebSocket URL."
  @spec socket_path() :: String.t()
  def socket_path, do: "/daemon/socket"

  @doc "Header carrying the daemon token, outside URL and query parameters."
  @spec token_header() :: String.t()
  def token_header, do: "x-helmsman-token"

  @doc """
  Returns the daemon's only Channel topic.

      iex> HelmsmanProtocol.topic(42)
      "daemon:42"
  """
  @spec topic(pos_integer()) :: String.t()
  def topic(daemon_id) when is_integer(daemon_id) and daemon_id > 0, do: "daemon:#{daemon_id}"
  @doc "CLI providers available in this protocol version."
  @spec providers() :: [atom()]
  def providers, do: @providers
end

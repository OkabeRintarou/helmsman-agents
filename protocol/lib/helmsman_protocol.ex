defmodule HelmsmanProtocol do
  @moduledoc """
  Wire protocol shared by the Helmsman server and the Helmsman daemon.
  """

  @version 7
  @providers ~w(claude codex copilot cursor)a

  @doc """
  Returns the protocol version spoken by this build.

  Server and daemon compare this number during the handshake.

  ## Examples

      iex> HelmsmanProtocol.version()
      7

  """
  @spec version() :: pos_integer()
  def version, do: @version
  @doc "Protocol version that introduced provider accounts."
  @spec provider_account_version() :: pos_integer()
  def provider_account_version, do: 2

  @doc "Protocol version that introduced provider account headers."
  @spec provider_account_headers_version() :: pos_integer()
  def provider_account_headers_version, do: 5

  @doc "Protocol version that introduced read-only checkouts (`RunSpec.Repo.mode`)."
  @spec snapshot_version() :: pos_integer()
  def snapshot_version, do: 6

  @doc "Protocol version that introduced local repositories and `repo_status`."
  @spec local_repositories_version() :: pos_integer()
  def local_repositories_version, do: 3

  @doc "Protocol version that introduced worktree cleanup checks."
  @spec cleanup_version() :: pos_integer()
  def cleanup_version, do: 4

  @doc "Protocol version that introduced local repository registration from the web."
  @spec repo_registration_version() :: pos_integer()
  def repo_registration_version, do: 7

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
      true
      iex> HelmsmanProtocol.compatible?(4)
      true
      iex> HelmsmanProtocol.compatible?(5)
      true
      iex> HelmsmanProtocol.compatible?(6)
      true
      iex> HelmsmanProtocol.compatible?(7)
      true
      iex> HelmsmanProtocol.compatible?(8)
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

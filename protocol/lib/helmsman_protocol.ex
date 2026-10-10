defmodule HelmsmanProtocol do
  @moduledoc """
  Wire protocol shared by the Helmsman server and the Helmsman daemon.
  """

  @version 1

  @doc """
  Returns the protocol version spoken by this build.

  Server and daemon compare this number during the handshake.

  ## Examples

      iex> HelmsmanProtocol.version()
      1

  """
  @spec version() :: pos_integer()
  def version, do: @version
end

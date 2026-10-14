defmodule HelmsmanDaemon.Keychain do
  @moduledoc """
  Generic-password store for the daemon token (macOS login keychain).

  Reads distinguish an item that does not exist (`{:error, :not_found}`) from an
  item that cannot be read right now (locked keychain, interaction not allowed,
  I/O); only the former may be treated as "this generation does not exist".
  """

  @type opts :: keyword()

  @callback add(service :: String.t(), account :: String.t(), token :: String.t(), opts()) ::
              :ok | {:error, term()}
  @callback find(service :: String.t(), account :: String.t(), opts()) ::
              {:ok, String.t()} | {:error, :not_found} | {:error, term()}
  @callback delete(service :: String.t(), account :: String.t(), opts()) ::
              :ok | {:error, :not_found} | {:error, term()}
end

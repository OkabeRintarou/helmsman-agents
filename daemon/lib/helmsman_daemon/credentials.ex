defmodule HelmsmanDaemon.Credentials do
  @moduledoc "Private device credentials; inspection never displays the token."
  require Logger
  alias HelmsmanDaemon.{AtomicFile, Paths}

  @enforce_keys [:server_url, :daemon_id, :token, :issued_at]
  defstruct [:server_url, :daemon_id, :token, :issued_at, workspaces: []]

  def read do
    path = Paths.credentials()

    with {:ok, stat} <- File.stat(path),
         :ok <- fix_mode(path, stat.mode),
         {:ok, data} <- File.read(path),
         {:ok, map} <- Jason.decode(data),
         {:ok, issued_at, _} <- DateTime.from_iso8601(map["issued_at"] || "") do
      decode(map, issued_at)
    end
  end

  defp decode(%{"server_url" => url, "daemon_id" => id, "token" => "hmd_" <> suffix} = map, time)
       when is_binary(url) and is_integer(id) and id > 0 and byte_size(suffix) > 0 do
    {:ok,
     %__MODULE__{
       server_url: url,
       daemon_id: id,
       token: "hmd_" <> suffix,
       issued_at: time,
       workspaces: Map.get(map, "workspaces", [])
     }}
  end

  defp decode(_, _), do: {:error, :invalid_credentials}

  def write(%__MODULE__{} = credentials, opts \\ []) do
    Paths.ensure!()
    data = credentials |> Map.from_struct() |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
    AtomicFile.write(Paths.credentials(), Jason.encode!(data), opts)
  end

  def delete do
    case File.rm(Paths.credentials()) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp fix_mode(path, mode) do
    if Bitwise.band(mode, 0o777) != 0o600 do
      Logger.warning("credentials permissions corrected to 0600")
      File.chmod(path, 0o600)
    else
      :ok
    end
  end
end

defimpl Inspect, for: HelmsmanDaemon.Credentials do
  import Inspect.Algebra

  def inspect(credentials, opts) do
    concat([
      "#HelmsmanDaemon.Credentials<",
      to_doc(
        %{
          daemon_id: credentials.daemon_id,
          server_url: credentials.server_url,
          token: "[REDACTED]"
        },
        opts
      ),
      ">"
    ])
  end
end

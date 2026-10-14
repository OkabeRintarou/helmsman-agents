defmodule HelmsmanDaemon.FileKeychain do
  @moduledoc "Cross-VM fake keychain, used only while the credential file lock is held."
  @behaviour HelmsmanDaemon.Keychain

  def items do
    case File.read(path()) do
      {:ok, data} -> Jason.decode!(data)
      {:error, :enoent} -> %{}
    end
  end

  @impl true
  def add(_service, account, token, _opts) do
    if Map.has_key?(items(), account) do
      {:error, :duplicate}
    else
      save(Map.put(items(), account, token))
    end
  end

  @impl true
  def find(_service, account, _opts) do
    case Map.fetch(items(), account) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def delete(_service, account, _opts) do
    if Map.has_key?(items(), account),
      do: save(Map.delete(items(), account)),
      else: {:error, :not_found}
  end

  defp path, do: Path.join(HelmsmanDaemon.Paths.home(), "fake-keychain.json")
  defp save(items), do: File.write(path(), Jason.encode!(items))
end

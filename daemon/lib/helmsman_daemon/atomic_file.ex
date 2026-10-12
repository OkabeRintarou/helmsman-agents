defmodule HelmsmanDaemon.AtomicFile do
  @moduledoc "Atomic private file replacement with cleanup on every failure."

  def write(path, contents, opts \\ []) do
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with {:ok, file} <- File.open(temp, [:write, :exclusive, :binary]) do
        try do
          File.chmod!(temp, 0o600)
          :ok = IO.binwrite(file, contents)
          :ok = :file.sync(file)
        after
          File.close(file)
        end

        Keyword.get(opts, :before_rename, fn -> :ok end).()
        File.rename(temp, path)
      end
    rescue
      _ -> {:error, :write_failed}
    after
      File.rm(temp)
    end
  end
end

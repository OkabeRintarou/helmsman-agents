defmodule Helmsman.Backup.Files do
  @moduledoc "Private local storage for backup artifacts; only relative opaque names are persisted."
  import Bitwise

  def directory(kind) when kind in [:exports, :imports] do
    Path.join(Application.fetch_env!(:helmsman, :data_dir), Atom.to_string(kind))
  end

  def ready do
    with :ok <- prepare(Application.fetch_env!(:helmsman, :data_dir)),
         :ok <- prepare(directory(:exports)),
         :ok <- prepare(directory(:imports)) do
      :ok
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp prepare(dir) do
    with :ok <- File.mkdir_p(dir),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(dir),
         true <- (mode &&& 0o222) != 0,
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def path(kind, name) when is_binary(name) do
    if name != "" and not String.contains?(name, ["/", "\\", "..", <<0>>]) do
      {:ok, Path.join(directory(kind), name)}
    else
      {:error, :invalid_file_name}
    end
  end

  def path(_kind, _name), do: {:error, :invalid_file_name}

  def create(kind, workspace_id) do
    with :ok <- ready() do
      name = "#{workspace_id}-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"
      {:ok, path} = path(kind, name)

      with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]),
           :ok <- File.chmod(path, 0o600) do
        {:ok, %{name: name, path: path, io: io}}
      else
        _ ->
          File.rm(path)
          {:error, :storage_unavailable}
      end
    end
  end

  def remove(kind, name) do
    with {:ok, path} <- path(kind, name), do: File.rm(path)
  end

  def copy_import(workspace_id, source) do
    with {:ok, file} <- create(:imports, workspace_id) do
      result =
        try do
          source
          |> File.stream!(64 * 1024)
          |> Enum.reduce_while(0, fn chunk, size ->
            next = size + byte_size(chunk)

            if next > Application.fetch_env!(:helmsman, :import_max_bytes) do
              {:halt, {:error, :too_large}}
            else
              :ok = IO.binwrite(file.io, chunk)
              {:cont, next}
            end
          end)
        rescue
          _ -> {:error, :storage_unavailable}
        after
          File.close(file.io)
        end

      case result do
        {:error, _} = error ->
          File.rm(file.path)
          error

        _ ->
          {:ok, file.name}
      end
    end
  end
end

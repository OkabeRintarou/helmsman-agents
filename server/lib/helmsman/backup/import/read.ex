defmodule Helmsman.Backup.Import.Read do
  @moduledoc "Reads JSON or gzip with a hard decompressed size limit."
  def file(path) do
    limit = Application.fetch_env!(:helmsman, :import_max_bytes)

    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        magic = IO.binread(io, 2)
        :file.position(io, 0)

        chunks =
          Stream.repeatedly(fn -> IO.binread(io, 16 * 1024) end)
          |> Stream.take_while(&(&1 != :eof))

        result = if magic == <<31, 139>>, do: inflate(chunks, limit), else: collect(chunks, limit)

        with {:ok, json} <- result do
          case Jason.decode(json) do
            {:ok, data} -> {:ok, data}
            {:error, _} -> {:error, {:invalid_import, [%{path: "$", message: "invalid JSON"}]}}
          end
        end
      after
        File.close(io)
      end
    end
  end

  defp collect(chunks, limit) do
    chunks
    |> Enum.reduce_while({[], 0}, fn
      {:error, _}, _ -> {:halt, {:error, :unreadable_file}}
      chunk, {acc, size} -> add(chunk, acc, size, limit)
    end)
    |> finish()
  end

  defp add(chunk, acc, size, limit) do
    size = size + IO.iodata_length(chunk)
    if size > limit, do: {:halt, {:error, :too_large}}, else: {:cont, {[chunk | acc], size}}
  end

  defp inflate(chunks, limit) do
    z = :zlib.open()
    :zlib.inflateInit(z, 31)

    try do
      result =
        chunks
        |> Enum.reduce_while({[], 0}, fn
          {:error, _}, _ -> {:halt, {:error, :unreadable_file}}
          chunk, state -> drain(z, chunk, state, limit)
        end)
        |> finish()

      if match?({:ok, _}, result), do: :zlib.inflateEnd(z)
      result
    rescue
      _ -> {:error, {:invalid_import, [%{path: "$", message: "invalid gzip"}]}}
    after
      :zlib.close(z)
    end
  end

  # safeInflate limits every output chunk, including a highly compressed input.
  defp drain(z, chunk, {acc, size}, limit) do
    {state, out} = :zlib.safeInflate(z, chunk)

    case add(out, acc, size, limit) do
      {:halt, error} -> {:halt, error}
      {:cont, next} when state == :continue -> drain(z, <<>>, next, limit)
      {:cont, next} -> {:cont, next}
    end
  end

  defp finish({:error, _} = error), do: error
  defp finish({chunks, _}), do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
end

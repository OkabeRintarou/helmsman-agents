defmodule Helmsman.Backup.Import.ReadTest do
  use ExUnit.Case, async: false
  alias Helmsman.Backup.Import.Read

  setup do
    path = Path.join(System.tmp_dir!(), "backup-read-#{System.unique_integer([:positive])}")
    old = Application.fetch_env!(:helmsman, :import_max_bytes)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:helmsman, :import_max_bytes, old)
    end)

    %{path: path}
  end

  test "accepts JSON and gzip and returns one invalid JSON error", ctx do
    for bytes <- ["{}", :zlib.gzip("{}")] do
      File.write!(ctx.path, bytes)
      assert {:ok, %{}} = Read.file(ctx.path)
    end

    File.write!(ctx.path, "{")
    assert {:error, {:invalid_import, [%{path: "$"}]}} = Read.file(ctx.path)
  end

  test "stops compressed expansion at the decompressed limit", ctx do
    Application.put_env(:helmsman, :import_max_bytes, 64 * 1024)
    File.write!(ctx.path, :zlib.gzip(String.duplicate("a", 10 * 1024 * 1024)))
    assert {:error, :too_large} = Read.file(ctx.path)
  end

  test "truncated gzip is rejected even when all JSON bytes decompressed", ctx do
    compressed = :zlib.gzip("{}")
    File.write!(ctx.path, binary_part(compressed, 0, byte_size(compressed) - 5))
    assert {:error, {:invalid_import, [_]}} = Read.file(ctx.path)
  end
end

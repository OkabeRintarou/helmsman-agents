defmodule Helmsman.Backup.FilesTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Helmsman.Backup.Files

  setup do
    old = Application.fetch_env!(:helmsman, :data_dir)
    dir = Path.join(System.tmp_dir!(), "backup-storage-#{System.unique_integer([:positive])}")
    Application.put_env(:helmsman, :data_dir, dir)

    on_exit(fn ->
      File.chmod(dir, 0o700)
      File.rm_rf(dir)
      Application.put_env(:helmsman, :data_dir, old)
    end)

    %{dir: dir}
  end

  test "directories and unpredictable files are private", ctx do
    assert :ok = Files.ready()

    for path <- [ctx.dir, Files.directory(:imports), Files.directory(:exports)] do
      assert (File.stat!(path).mode &&& 0o777) == 0o700
    end

    assert {:ok, file} = Files.create(:imports, 42)
    File.close(file.io)
    assert file.name =~ ~r/^42-[a-f0-9]{32}$/
    assert (File.stat!(file.path).mode &&& 0o777) == 0o600
  end

  test "rejects traversal and refuses read-only storage", ctx do
    for name <- ["../file", "a/file", "a..b", "a\\file", "", <<0>>] do
      assert {:error, :invalid_file_name} = Files.path(:imports, name)
    end

    File.mkdir_p!(ctx.dir)
    File.chmod!(ctx.dir, 0o500)
    assert {:error, :storage_unavailable} = Files.ready()
  end

  test "test storage is partitioned" do
    assert Application.fetch_env!(:helmsman, :data_dir) |> is_binary()
    # The config source binds the partition to the default directory.
    assert File.read!("config/config.exs") =~ "MIX_TEST_PARTITION"
  end

  test "upload overflow deletes the partial copy", ctx do
    old = Application.fetch_env!(:helmsman, :import_max_bytes)
    Application.put_env(:helmsman, :import_max_bytes, 32)
    on_exit(fn -> Application.put_env(:helmsman, :import_max_bytes, old) end)
    source = Path.join(ctx.dir, "source")
    :ok = Files.ready()
    File.write!(source, String.duplicate("x", 64))
    assert {:error, :too_large} = Files.copy_import(42, source)
    assert File.ls!(Files.directory(:imports)) == []
  end
end

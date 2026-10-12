defmodule HelmsmanDaemon.Adapters.CodexHomeTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex

  test "dedicated persistent home leaves user and inherited Codex homes untouched", %{
    tmp_dir: dir
  } do
    user = Path.join(dir, "user")
    inherited = Path.join(dir, "inherited")
    File.mkdir_p!(Path.join(user, ".codex"))
    File.mkdir_p!(inherited)

    paths =
      for root <- [Path.join(user, ".codex"), inherited],
          file <- ["config.toml", "auth.json"],
          do: Path.join(root, file)

    Enum.each(paths, &File.write!(&1, "private-owner-file"))
    before = Map.new(paths, &{&1, {File.read!(&1), File.stat!(&1).mtime}})
    previous = Map.take(System.get_env(), ["HOME", "CODEX_HOME"])
    System.put_env(%{"HOME" => user, "CODEX_HOME" => inherited})

    try do
      assert {:ok, launch} = Codex.prepare(spec(1), dir, dir)
      assert launch.env == [{"CODEX_HOME", Path.join(dir, "codex")}]
      assert Bitwise.band(File.stat!(Path.join(dir, "codex")).mode, 0o777) == 0o700
      assert File.ls!(Path.join(dir, "codex")) == []
      assert before == Map.new(paths, &{&1, {File.read!(&1), File.stat!(&1).mtime}})
    after
      Enum.each(["HOME", "CODEX_HOME"], &System.delete_env/1)
      System.put_env(previous)
    end
  end
end

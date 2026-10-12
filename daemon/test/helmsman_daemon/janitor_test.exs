defmodule HelmsmanDaemon.JanitorTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Janitor

  test "eight-day logs removed, six-day logs preserved" do
    now = System.os_time(:second)

    for {id, days} <- [{1, 8}, {2, 6}] do
      Paths.private_dir!(Paths.run(id))
      path = Path.join(Paths.run(id), "raw.log")
      File.write!(path, "log")
      File.touch!(path, now - days * 86_400)
    end

    Janitor.clean(now)
    refute File.exists?(Paths.run(1))
    assert File.exists?(Path.join(Paths.run(2), "raw.log"))
  end
end

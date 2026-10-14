defmodule HelmsmanDaemon.LoggerFileTest do
  # The background service logs to a rotated file only on macOS.
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  @moduletag :macos
  require Logger
  alias HelmsmanDaemon.LogFile

  setup do
    {:ok, default} = :logger.get_handler_config(:default)

    on_exit(fn ->
      :logger.remove_handler(:helmsman_file)
      :logger.add_handler(:default, default.module, default)
    end)

    :ok
  end

  test "--service on macOS logs to logs/daemon.log, 10 MB x 5" do
    assert :ok = LogFile.setup(:macos)
    assert LogFile.path() == Path.join([Paths.home(), "logs", "daemon.log"])
    assert Bitwise.band(File.stat!(Path.dirname(LogFile.path())).mode, 0o777) == 0o700

    {:ok, %{config: config}} = :logger.get_handler_config(:helmsman_file)
    assert config.file == String.to_charlist(LogFile.path())
    assert config.max_no_bytes == 10 * 1024 * 1024
    assert config.max_no_files == 5
    assert {:error, _} = :logger.get_handler_config(:default)

    Logger.warning("written to the daemon log")
    :logger_std_h.filesync(:helmsman_file)
    assert File.read!(LogFile.path()) =~ "written to the daemon log"
  end
end

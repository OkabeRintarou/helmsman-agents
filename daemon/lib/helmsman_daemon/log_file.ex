defmodule HelmsmanDaemon.LogFile do
  @moduledoc """
  Log file of the macOS background service: `<home>/logs/daemon.log`, rotated
  at 10 MB keeping 5 files. Linux services log to journald through standard
  output; foreground runs log to standard output on both platforms.
  """
  alias HelmsmanDaemon.Paths

  @handler :helmsman_file
  @max_bytes 10 * 1024 * 1024
  @max_files 5

  def path, do: Path.join([Paths.home(), "logs", "daemon.log"])

  @doc "Adds the file handler on macOS (replacing standard output); no-op elsewhere."
  def setup(:macos) do
    Paths.private_dir!(Path.dirname(path()))
    _ = :logger.remove_handler(@handler)

    :ok =
      :logger.add_handler(@handler, :logger_std_h, %{
        config: %{
          file: String.to_charlist(path()),
          max_no_bytes: @max_bytes,
          max_no_files: @max_files
        },
        formatter: Logger.default_formatter(colors: [enabled: false])
      })

    # launchd's StandardOutPath is not rotated; keep logs in the rotated file.
    _ = :logger.remove_handler(:default)
    :ok
  end

  def setup(_platform), do: :ok
end

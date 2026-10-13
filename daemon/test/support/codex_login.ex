defmodule HelmsmanDaemon.CodexLogin do
  @moduledoc "Offline Codex login probe and app-server launch sentinel."

  def install(dir, mode \\ "0") do
    path = Path.join(dir, "codex-login")
    mode_path = path <> ".mode"
    File.write!(mode_path, mode)

    File.write!(path, """
    #!/bin/sh
    case "$1 $2" in
      'login status')
        printf '%s' "$CODEX_HOME" > "$0.home"
        /usr/bin/env | /usr/bin/cut -d= -f1 > "$0.env-names"
        printf '%s' "$$" > "$0.pid"
        case "$(/bin/cat "$0.mode")" in
          barrier)
            : > "$0.ready"
            while [ ! -f "$0.release" ]; do /bin/sleep 0.01; done
            exit "$(/bin/cat "$0.result")"
            ;;
          hang) /bin/sleep 30 ;;
          *) printf 'PRIVATE_LOGIN_OUTPUT'; exit "$(/bin/cat "$0.mode")" ;;
        esac
        ;;
      '--version ') printf 'codex-cli 0.162.1' ;;
      *) printf started > "$0.started"; exit 2 ;;
    esac
    """)

    File.chmod!(path, 0o700)
    keys = [:codex_executable, :codex_login_timeout_ms]
    old = Map.new(keys, &{&1, Application.fetch_env(:helmsman_daemon, &1)})
    Application.put_env(:helmsman_daemon, :codex_executable, path)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:helmsman_daemon, key, value)
        {key, :error} -> Application.delete_env(:helmsman_daemon, key)
      end)
    end)

    path
  end

  def mode(path, mode), do: File.write!(path <> ".mode", mode)
end

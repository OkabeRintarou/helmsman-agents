defmodule HelmsmanWeb.Plugs.DaemonDownload do
  @moduledoc """
  The public download endpoints (`add-release-distribution` decision 11),
  in the endpoint before the router: no session, no authentication, rate
  limited per client IP (`:public_download_ip`, 429 with `retry-after`).

    * `GET /install.sh` - the install script (`HelmsmanWeb.InstallScript`).
    * `GET /downloads/daemon/<target>` and `<target>.sha256`, `target` one
      of `linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`:
      `helmsman-<target>[.sha256]` from `HELMSMAN_DAEMON_DIST_DIR` as an
      attachment; when it is not there, a 302 to
      `HELMSMAN_DAEMON_DOWNLOAD_URL/helmsman-<target>[.sha256]`; without
      either, 404 with an explanation. Anything else under
      `/downloads/daemon/` is 404.

  `HEAD` is answered like `GET`, without the body.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.RateLimit

  @targets ~w(linux-x64 linux-arm64 macos-x64 macos-arm64)
  @files Enum.flat_map(@targets, &["helmsman-#{&1}", "helmsman-#{&1}.sha256"])
  @not_bundled "This server does not bundle daemon binaries; download them from the release page.\n"

  @doc "The daemon targets the endpoint serves."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["install.sh"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    with_rate_limit(conn, fn conn ->
      conn
      |> put_resp_content_type("text/x-shellscript")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, HelmsmanWeb.InstallScript.render())
      |> halt()
    end)
  end

  def call(%Plug.Conn{method: method, path_info: ["downloads", "daemon" | rest]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    with_rate_limit(conn, fn conn ->
      case rest do
        [name] when name in @targets -> serve(conn, "helmsman-" <> name)
        [name] -> serve_checksum(conn, name)
        _ -> not_found(conn, "Unknown daemon target.\n")
      end
    end)
  end

  def call(conn, _opts), do: conn

  defp serve_checksum(conn, name) do
    case String.split(name, ".", parts: 2) do
      [target, "sha256"] when target in @targets -> serve(conn, "helmsman-#{target}.sha256")
      _ -> not_found(conn, "Unknown daemon target.\n")
    end
  end

  defp serve(conn, file) when file in @files do
    cond do
      path = local_file(file) -> send_download(conn, file, path)
      url = download_url() -> conn |> redirect(url <> "/" <> file) |> halt()
      true -> not_found(conn, @not_bundled)
    end
  end

  defp local_file(file) do
    with dir when is_binary(dir) and dir != "" <- Application.get_env(:helmsman, :daemon_dist_dir),
         path = Path.join(dir, file),
         true <- File.regular?(path) do
      path
    else
      _ -> nil
    end
  end

  defp download_url do
    case Application.get_env(:helmsman, :daemon_download_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp send_download(conn, file, path) do
    conn =
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{file}"))
      |> put_resp_header("cache-control", "no-cache")

    case conn.method do
      "HEAD" ->
        %File.Stat{size: size} = File.stat!(path)

        conn
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_resp(200, "")
        |> halt()

      "GET" ->
        conn |> send_file(200, path) |> halt()
    end
  end

  defp redirect(conn, url) do
    conn
    |> put_resp_header("location", url)
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(302, "")
  end

  defp not_found(conn, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, message)
    |> halt()
  end

  defp with_rate_limit(conn, fun) do
    case RateLimit.check_retry(:public_download_ip, RateLimit.ip_key(conn.remote_ip)) do
      :ok ->
        fun.(conn)

      {:error, :rate_limited, retry_after_ms} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header(
          "retry-after",
          Integer.to_string(max(div(retry_after_ms + 999, 1000), 1))
        )
        |> send_resp(429, "Too many requests.\n")
        |> halt()
    end
  end
end

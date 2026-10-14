defmodule HelmsmanWeb.Plugs.DaemonDownloadTest do
  # daemon-distribution "安装脚本与下载" (add-release-distribution decision
  # 11). Changes the binary directory and download URL: not async.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.RateLimitHelpers

  @targets ~w(linux-x64 linux-arm64 macos-x64 macos-arm64)

  setup %{conn: conn} do
    for key <- [:daemon_dist_dir, :daemon_download_url] do
      previous = Application.get_env(:helmsman, key)
      on_exit(fn -> Application.put_env(:helmsman, key, previous) end)
      Application.put_env(:helmsman, key, nil)
    end

    # A client address of its own: the rate limit's bucket.
    %{conn: %{conn | remote_ip: unique_ip()}}
  end

  defp dist_dir(%{tmp_dir: dir}) do
    for target <- @targets do
      File.write!(Path.join(dir, "helmsman-#{target}"), "binary of #{target}")

      File.write!(
        Path.join(dir, "helmsman-#{target}.sha256"),
        "#{String.duplicate("a", 64)}  helmsman-#{target}\n"
      )
    end

    File.write!(Path.join(dir, "secret.txt"), "not served")
    Application.put_env(:helmsman, :daemon_dist_dir, dir)
    dir
  end

  test "neither a directory nor a download URL (scenario): 404 with an explanation", %{conn: conn} do
    conn = get(conn, "/downloads/daemon/linux-x64")
    assert conn.status == 404
    assert conn.resp_body =~ "This server does not bundle daemon binaries"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
  end

  @tag :tmp_dir
  test "each of the four targets from the directory, as an attachment", %{conn: conn} = ctx do
    dist_dir(ctx)

    for target <- @targets do
      resp = conn |> recycle() |> get("/downloads/daemon/#{target}")
      assert resp.status == 200
      assert resp.resp_body == "binary of #{target}"
      assert get_resp_header(resp, "content-type") == ["application/octet-stream"]

      assert get_resp_header(resp, "content-disposition") ==
               [~s(attachment; filename="helmsman-#{target}")]
    end
  end

  @tag :tmp_dir
  test "the .sha256 file", %{conn: conn} = ctx do
    dist_dir(ctx)
    resp = get(conn, "/downloads/daemon/macos-arm64.sha256")
    assert resp.status == 200
    assert resp.resp_body == "#{String.duplicate("a", 64)}  helmsman-macos-arm64\n"

    assert get_resp_header(resp, "content-disposition") ==
             [~s(attachment; filename="helmsman-macos-arm64.sha256")]
  end

  @tag :tmp_dir
  test "HEAD: the headers and length, no body", %{conn: conn} = ctx do
    dist_dir(ctx)
    resp = head(conn, "/downloads/daemon/linux-arm64")
    assert resp.status == 200
    assert resp.resp_body == ""

    assert get_resp_header(resp, "content-length") == [
             to_string(byte_size("binary of linux-arm64"))
           ]

    assert get_resp_header(resp, "content-type") == ["application/octet-stream"]
  end

  @tag :tmp_dir
  test "unknown targets and path traversal are 404 and serve nothing", %{conn: conn} = ctx do
    dist_dir(ctx)

    for path <- [
          "/downloads/daemon/windows-x64",
          "/downloads/daemon/linux-x86",
          "/downloads/daemon/helmsman-linux-x64",
          "/downloads/daemon/linux-x64.md5",
          "/downloads/daemon/linux-x64.sha256.sha256",
          "/downloads/daemon/secret.txt",
          "/downloads/daemon/../secret.txt",
          "/downloads/daemon/../../../../etc/passwd",
          "/downloads/daemon/..%2Fsecret.txt",
          "/downloads/daemon/linux-x64/../../secret.txt",
          "/downloads/daemon/",
          "/downloads/daemon"
        ] do
      resp = conn |> recycle() |> get(path)
      assert resp.status == 404, path
      refute resp.resp_body =~ "not served", path
      refute resp.resp_body =~ "root:", path
    end
  end

  test "only a download URL: 302 to it", %{conn: conn} do
    Application.put_env(
      :helmsman,
      :daemon_download_url,
      "https://example.com/releases/download/v0.11.0"
    )

    resp = get(conn, "/downloads/daemon/linux-arm64")
    assert resp.status == 302

    assert get_resp_header(resp, "location") ==
             ["https://example.com/releases/download/v0.11.0/helmsman-linux-arm64"]

    resp = conn |> recycle() |> get("/downloads/daemon/macos-x64.sha256")

    assert get_resp_header(resp, "location") ==
             ["https://example.com/releases/download/v0.11.0/helmsman-macos-x64.sha256"]
  end

  @tag :tmp_dir
  test "a file missing from the directory falls back to the download URL", %{conn: conn} = ctx do
    File.rm!(Path.join(dist_dir(ctx), "helmsman-macos-x64"))
    Application.put_env(:helmsman, :daemon_download_url, "https://example.com/dl/")

    assert conn |> get("/downloads/daemon/macos-x64") |> get_resp_header("location") ==
             ["https://example.com/dl/helmsman-macos-x64"]

    assert conn |> recycle() |> get("/downloads/daemon/linux-x64") |> response(200)
  end

  test "the 61st request in a minute from one address is 429 with retry-after", %{conn: conn} do
    Application.put_env(:helmsman, :daemon_download_url, "https://example.com/dl")

    for i <- 1..60 do
      path = if rem(i, 2) == 0, do: "/install.sh", else: "/downloads/daemon/linux-x64"
      assert (conn |> recycle() |> get(path)).status in [200, 302]
    end

    resp = conn |> recycle() |> get("/downloads/daemon/linux-x64")
    assert resp.status == 429
    assert [retry_after] = get_resp_header(resp, "retry-after")
    assert String.to_integer(retry_after) in 1..60

    # Another address is not limited.
    assert (build_conn() |> Map.put(:remote_ip, unique_ip()) |> get("/install.sh")).status == 200
  end

  test "other methods are not handled here", %{conn: conn} do
    assert post(conn, "/downloads/daemon/linux-x64").status == 404
    assert post(conn |> recycle(), "/install.sh").status == 404
  end

  test "no session cookie and no CSP on downloads", %{conn: conn} do
    resp = get(conn, "/install.sh")
    assert get_resp_header(resp, "set-cookie") == []
    assert get_resp_header(resp, "content-security-policy") == []
  end
end

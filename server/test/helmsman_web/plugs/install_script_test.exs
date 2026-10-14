defmodule HelmsmanWeb.Plugs.InstallScriptTest do
  # daemon-distribution "安装脚本与下载": /install.sh rendered from
  # priv/install.sh.eex, then run with a fake `uname` against a local
  # Bandit download server (the real download plug). Changes the binary
  # directory and runs external commands: not async.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.RateLimitHelpers

  alias HelmsmanWeb.InstallScript

  @version :helmsman |> Application.spec(:vsn) |> to_string()

  # Serves the download endpoints only, as the server would.
  defmodule Downloads do
    @moduledoc false
    @behaviour Plug

    alias HelmsmanWeb.Plugs.DaemonDownload

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn = DaemonDownload.call(conn, [])
      if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  describe "rendering" do
    test "embeds the public URL and version, no token, valid sh" do
      script = InstallScript.render("https://hm.example.com", "0.11.0")

      assert script =~ "server='https://hm.example.com'"
      assert script =~ "version='0.11.0'"
      assert script =~ "curl -fsSL https://hm.example.com/install.sh | sh"
      assert script =~ ~s(helmsman login --server $server)
      assert script =~ ~s(${HELMSMAN_BIN_DIR:-$HOME/.local/bin})
      assert script =~ "unset HELMSMAN_INSTALL_DIR"
      refute script =~ ~r/\bhm[a-z]?_[A-Za-z0-9]/
      assert_sh_syntax(script)
    end

    test "quotes what it embeds" do
      script = InstallScript.render("https://evil.example.com/'; rm -rf ~; '\nx", "1'2")
      assert script =~ ~S(server='https://evil.example.com/'\''; rm -rf ~; '\''x')
      assert script =~ ~S(version='1'\''2')
      assert_sh_syntax(script)
    end

    test "GET /install.sh serves the instance's script", %{conn: conn} do
      conn = get(%{conn | remote_ip: unique_ip()}, "/install.sh")
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/x-shellscript"
      assert conn.resp_body == InstallScript.render()
      assert conn.resp_body =~ "server='http://localhost:4000'"
      assert conn.resp_body =~ "version='#{@version}'"
      refute conn.resp_body =~ ~r/\bhm[a-z]?_[A-Za-z0-9]/
    end
  end

  defp assert_sh_syntax(script) do
    {output, status} = System.cmd("sh", ["-n", "-c", script], stderr_to_stdout: true)
    assert status == 0, output
  end

  describe "running the script" do
    setup %{tmp_dir: tmp} = ctx do
      previous = Application.get_env(:helmsman, :daemon_dist_dir)
      on_exit(fn -> Application.put_env(:helmsman, :daemon_dist_dir, previous) end)

      dirs =
        for name <- ~w(dist home tmp fakebin), into: %{} do
          dir = Path.join(tmp, name)
          File.mkdir_p!(dir)
          {String.to_atom(name), dir}
        end

      Application.put_env(:helmsman, :daemon_dist_dir, dirs.dist)

      server =
        start_supervised!({Bandit, plug: Downloads, ip: :loopback, port: 0, startup_log: false})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      url = "http://127.0.0.1:#{port}"

      script = Path.join(tmp, "install.sh")
      File.write!(script, InstallScript.render(url, @version))

      for target <- ctx[:targets] || ["linux-arm64"], do: put_binary(dirs.dist, target)
      fake_uname(dirs.fakebin, ctx[:uname] || {"Linux", "aarch64"})

      Map.merge(dirs, %{url: url, script: script})
    end

    @tag :tmp_dir
    test "install (scenario): linux-arm64 to ~/.local/bin, 0755, the version and next steps",
         ctx do
      {output, status} = run(ctx)
      assert status == 0, output

      dest = Path.join(ctx.home, ".local/bin/helmsman")
      assert File.read!(dest) == binary("linux-arm64")
      assert File.stat!(dest).mode |> Bitwise.band(0o777) == 0o755

      assert output =~ "Downloading helmsman #{@version} (linux-arm64) from #{ctx.url}"
      assert output =~ "helmsman #{@version} (protocol 6, linux-arm64)"
      assert output =~ "helmsman login --server #{ctx.url}"
      assert output =~ "helmsman daemon start"
      # ~/.local/bin is not on PATH here.
      assert output =~ "is not on your PATH"
      refute output =~ "daemon restart"
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    test "an existing helmsman is replaced by a rename", ctx do
      bin = Path.join(ctx.home, ".local/bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "helmsman"), "old version")
      %File.Stat{inode: old_inode} = File.stat!(Path.join(bin, "helmsman"))

      {output, 0} = run(ctx)
      assert output =~ "Installed"
      assert File.read!(Path.join(bin, "helmsman")) == binary("linux-arm64")
      refute File.stat!(Path.join(bin, "helmsman")).inode == old_inode
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    test "checksum mismatch (scenario): non-zero, the old binary unchanged, no temporary files",
         ctx do
      File.write!(Path.join(ctx.dist, "helmsman-linux-arm64"), "tampered")
      bin = Path.join(ctx.home, ".local/bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "helmsman"), "old version")

      {output, status} = run(ctx)
      assert status != 0
      assert output =~ "checksum mismatch"
      assert File.read!(Path.join(bin, "helmsman")) == "old version"
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    test "a checksum file that is not a SHA-256 fails", ctx do
      File.write!(Path.join(ctx.dist, "helmsman-linux-arm64.sha256"), "../../etc/passwd\n")
      {output, status} = run(ctx)
      assert status != 0
      assert output =~ "is not a SHA-256 checksum"
      refute File.exists?(Path.join(ctx.home, ".local/bin/helmsman"))
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    @tag uname: {"FreeBSD", "amd64"}
    test "unsupported operating system (scenario)", ctx do
      {output, status} = run(ctx)
      assert status != 0
      assert output =~ "unsupported operating system: FreeBSD"
      refute File.exists?(Path.join(ctx.home, ".local/bin"))
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    @tag uname: {"Linux", "i686"}
    test "unsupported architecture (scenario)", ctx do
      {output, status} = run(ctx)
      assert status != 0
      assert output =~ "unsupported architecture: i686"
      refute File.exists?(Path.join(ctx.home, ".local/bin"))
    end

    @tag :tmp_dir
    @tag uname: {"Darwin", "arm64"}, targets: ["macos-arm64"]
    test "macOS on Apple silicon gets macos-arm64", ctx do
      {output, 0} = run(ctx)
      assert output =~ "(macos-arm64)"
      assert File.read!(Path.join(ctx.home, ".local/bin/helmsman")) == binary("macos-arm64")
    end

    @tag :tmp_dir
    @tag uname: {"Linux", "x86_64"}, targets: ["linux-x64"]
    test "HELMSMAN_BIN_DIR on PATH: installed there, no PATH hint", ctx do
      dir = Path.join(ctx.tmp_dir, "opt bin")
      {output, 0} = run(ctx, [{"HELMSMAN_BIN_DIR", dir}], prepend_path: [dir])
      assert File.read!(Path.join(dir, "helmsman")) == binary("linux-x64")
      refute output =~ "is not on your PATH"
      refute File.exists?(Path.join(ctx.home, ".local/bin"))
    end

    @tag :tmp_dir
    test "HELMSMAN_INSTALL_DIR in the environment: not the install directory, unset for the binary",
         ctx do
      payload = Path.join(ctx.tmp_dir, "payload")
      {output, status} = run(ctx, [{"HELMSMAN_INSTALL_DIR", payload}])
      assert status == 0, output

      assert File.read!(Path.join(ctx.home, ".local/bin/helmsman")) == binary("linux-arm64")
      assert output =~ "HELMSMAN_INSTALL_DIR=unset"
      refute output =~ payload
      refute File.exists?(payload)
      assert_no_leftovers(ctx)
    end

    @tag :tmp_dir
    test "an installed service: a restart hint, never a restart", ctx do
      units = Path.join(ctx.home, ".config/systemd/user")
      File.mkdir_p!(units)
      File.write!(Path.join(units, "helmsman-daemon.service"), "[Unit]\n")

      calls = Path.join(ctx.tmp_dir, "calls")

      for command <- ~w(systemctl launchctl) do
        fake(ctx.fakebin, command, ~s(echo "#{command} $*" >> "#{calls}"))
      end

      {output, 0} = run(ctx)
      assert output =~ "helmsman daemon restart"
      refute File.exists?(calls)
    end

    @tag :tmp_dir
    test "without curl: downloads with wget", ctx do
      tools = Path.join(ctx.tmp_dir, "tools")
      File.mkdir_p!(tools)

      for command <- ~w(mkdir mktemp rm cp mv chmod sha256sum) do
        File.ln_s!(System.find_executable(command), Path.join(tools, command))
      end

      wget_log = Path.join(ctx.tmp_dir, "wget.log")

      fake(
        ctx.fakebin,
        "wget",
        ~s(echo "$*" >> "#{wget_log}"\nexec #{System.find_executable("wget")} "$@")
      )

      {output, status} = run(ctx, [], path: [ctx.fakebin, tools])
      assert status == 0, output
      assert File.read!(Path.join(ctx.home, ".local/bin/helmsman")) == binary("linux-arm64")
      assert File.read!(wget_log) =~ "/downloads/daemon/linux-arm64"
      assert_no_leftovers(ctx)
    end
  end

  # The fake binary prints its version like the real one, and whether it
  # sees HELMSMAN_INSTALL_DIR (Burrito's payload directory).
  defp binary(target),
    do:
      "#!/bin/sh\necho \"helmsman #{@version} (protocol 6, #{target})\"\n" <>
        "echo \"HELMSMAN_INSTALL_DIR=${HELMSMAN_INSTALL_DIR-unset}\"\n"

  defp put_binary(dist, target) do
    content = binary(target)
    File.write!(Path.join(dist, "helmsman-#{target}"), content)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    File.write!(Path.join(dist, "helmsman-#{target}.sha256"), "#{hash}  helmsman-#{target}\n")
  end

  defp fake_uname(fakebin, {os, arch}),
    do: fake(fakebin, "uname", ~s(case "$1" in -s\) echo #{os} ;; -m\) echo #{arch} ;; esac))

  defp fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  # Runs the script with sh, HOME and TMPDIR in the test directory and the
  # fake commands first on PATH.
  defp run(ctx, env \\ [], opts \\ []) do
    path =
      (Keyword.get(opts, :prepend_path, []) ++
         Keyword.get(opts, :path, [ctx.fakebin | String.split(System.get_env("PATH"), ":")]))
      |> Enum.join(":")

    env =
      [
        {"HOME", ctx.home},
        {"TMPDIR", ctx.tmp},
        {"PATH", path},
        {"HELMSMAN_BIN_DIR", nil},
        {"HELMSMAN_INSTALL_DIR", nil},
        {"HELMSMAN_HOME", nil}
      ] ++ env

    System.cmd("/bin/sh", [ctx.script], env: env, stderr_to_stdout: true)
  end

  defp assert_no_leftovers(ctx) do
    assert File.ls!(ctx.tmp) == []
    bin = Path.join(ctx.home, ".local/bin")

    if File.dir?(bin) do
      assert bin |> File.ls!() |> Enum.reject(&(&1 == "helmsman")) == []
    end
  end
end

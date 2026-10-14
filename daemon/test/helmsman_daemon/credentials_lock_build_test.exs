defmodule HelmsmanDaemon.CredentialsLockBuildTest do
  # The build step of daemon/mix.exs that puts the compiled credential lock
  # helper into the build path (and so into releases).
  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.CredentialsLock

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    output = Path.join([dir, "src", "priv", "credentials_lock"])
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, "new-helper\n")
    File.chmod!(output, 0o755)
    build = Path.join([dir, "build", "lib", "helmsman_daemon"])
    File.mkdir_p!(build)
    %{output: output, build_priv: Path.join(build, "priv")}
  end

  test "links priv/ into a build path that has none yet", %{output: output, build_priv: priv} do
    assert :ok = CredentialsLock.sync_build_priv!(output, priv)
    assert {:ok, _} = File.read_link(priv)
    assert CredentialsLock.same_helper?(output, Path.join(priv, "credentials_lock"))
  end

  test "replaces a stale copy that Mix's copy fallback keeps (same size and mtime)",
       %{output: output, build_priv: priv} do
    copy = Path.join(priv, "credentials_lock")
    File.mkdir_p!(priv)
    File.write!(copy, "old-helper\n")
    File.chmod!(copy, 0o755)
    File.touch!(output, 1_700_000_000)
    File.touch!(copy, 1_700_000_000)

    assert :ok = CredentialsLock.sync_build_priv!(output, priv)
    assert File.read!(copy) == "new-helper\n"
    assert CredentialsLock.same_helper?(output, copy)
    assert {:error, :einval} = File.read_link(priv)
  end

  test "same_helper? needs an executable regular file with the same bytes",
       %{output: output, tmp_dir: dir} do
    copy = Path.join(dir, "copy")
    refute CredentialsLock.same_helper?(output, copy)

    File.write!(copy, "new-helper\n")
    File.chmod!(copy, 0o644)
    refute CredentialsLock.same_helper?(output, copy)

    File.chmod!(copy, 0o755)
    assert CredentialsLock.same_helper?(output, copy)

    File.write!(copy, "old-helper\n")
    refute CredentialsLock.same_helper?(output, copy)
    refute CredentialsLock.same_helper?(Path.join(dir, "missing"), copy)
  end
end

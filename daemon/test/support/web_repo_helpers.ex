defmodule HelmsmanDaemon.WebRepoHelpers do
  @moduledoc """
  Fixtures for web registration of local repositories: a user home below the
  system temp directory (outside this checkout, so git never discovers it),
  the daemon home at `~/.helmsman`, roots, repositories and pushes.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  import HelmsmanDaemon.LocalRepoHelpers
  alias HelmsmanDaemon.{LocalRepos, Paths}
  alias HelmsmanProtocol.Push

  @doc "Sets HOME to a fresh scratch directory and the daemon home to `~/.helmsman`."
  def web_home do
    {:ok, home} = LocalRepos.real_path(scratch())
    System.put_env("HOME", home)
    System.put_env("HELMSMAN_HOME", Path.join(home, ".helmsman"))
    Paths.ensure!()
    home
  end

  def config_path, do: LocalRepos.config_path()
  def config!, do: File.read!(config_path())
  def write_config!(text), do: File.write!(config_path(), text)

  @doc "Writes `[repos] allowed_roots` (and optional extra TOML before it)."
  def allow!(roots, extra \\ "") do
    list = Enum.map_join(roots, ", ", &inspect/1)
    write_config!(extra <> "[repos]\nallowed_roots = [#{list}]\n")
  end

  def decoded, do: Toml.decode!(config!())
  def configured, do: Map.get(decoded(), "local_repositories", [])

  @doc "Refuses fixture paths outside the system temp directory (never the real home)."
  def scratch_path!(path) do
    tmp = System.tmp_dir!() |> Path.expand()
    {:ok, real_tmp} = LocalRepos.real_path(tmp)

    unless Enum.any?([tmp, real_tmp], &String.starts_with?(Path.expand(path), &1 <> "/")),
      do: raise("fixture path outside #{tmp}: #{path}")

    path
  end

  @doc "A git repository with one commit at `path`."
  def repo!(path) do
    scratch_path!(path)
    user_repo(Path.dirname(path), Path.basename(path))
  end

  def bare!(path) do
    scratch_path!(path)
    File.mkdir_p!(Path.dirname(path))
    git!(Path.dirname(path), ["init", "-q", "--bare", path])
    path
  end

  def dir!(path) do
    scratch_path!(path)
    File.mkdir_p!(path)
    path
  end

  def link!(target, path) do
    scratch_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
    path
  end

  def request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  def register_push(attrs) do
    struct!(
      Push.RepoRegister,
      Map.merge(
        %{request_id: request_id(), root: "~/code", path: "app", name: "app", workspaces: [7]},
        Map.new(attrs)
      )
    )
  end

  def remove_push(name), do: %Push.RepoRemove{request_id: request_id(), name: name}

  @doc "A wrapper around git that appends every argv to `log` and forwards."
  def logging_git(dir, extra_env \\ "") do
    log = Path.join(dir, "git-argv.log")
    wrapper = Path.join(dir, "logging-git")

    File.write!(wrapper, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{log}'
    #{extra_env}exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(wrapper, 0o755)
    on_exit(fn -> File.rm(wrapper) end)
    %{executable: wrapper, log: log}
  end
end

defmodule HelmsmanDaemon.LocalRepoHelpers do
  @moduledoc """
  User repositories for local-mode tests. They live under the system temp
  directory (never inside this checkout, so git cannot discover a parent
  repository) and are removed when the test exits.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias HelmsmanDaemon.{Git, Paths}

  @doc "Moves the daemon home below `tmp_dir` so user repositories are outside it."
  def isolate_home(tmp_dir) do
    home = Path.join(tmp_dir, "home")
    System.put_env("HELMSMAN_HOME", home)
    Paths.ensure!()
    home
  end

  def git_context,
    do:
      Git.context(Paths.home(), nil,
        identity: Git.identity("Owner", "http://localhost"),
        command_timeout_ms: 30_000
      )

  def git!(cwd, args) do
    case Git.run(args, cwd, git_context()) do
      {:ok, output} -> String.trim(output)
      result -> raise "user repo git #{inspect(args)} failed: #{inspect(result)}"
    end
  end

  def git(cwd, args), do: Git.run(args, cwd, git_context())

  @doc "A fresh scratch root below the system temp directory."
  def scratch do
    root = Path.join(System.tmp_dir!(), "hm-local-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @doc "A normal repository with one commit on `main`, checked out on `main`."
  def user_repo(root \\ scratch(), name \\ "app") do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git!(path, ["init", "-q", "-b", "main"])
    commit(path, "base.txt", "base\n", "base")
    path
  end

  def commit(path, file, text, message) do
    File.write!(Path.join(path, file), text)
    git!(path, ["add", "-A"])
    git!(path, ["commit", "-q", "-m", message])
    git!(path, ["rev-parse", "HEAD"])
  end

  @doc "Writes config.toml directly (the CLI is tested separately)."
  def configure(entries, extra \\ "") do
    blocks =
      Enum.map_join(entries, "\n", fn {name, path, workspaces} ->
        "[[local_repositories]]\nname = #{inspect(name)}\npath = #{inspect(path)}\nworkspaces = [#{Enum.join(workspaces, ", ")}]\n"
      end)

    File.write!(Path.join(Paths.home(), "config.toml"), extra <> blocks)
  end

  def served(list) do
    Paths.private_dir!(Paths.state())

    File.write!(
      Path.join(Paths.state(), "workspaces.json"),
      Jason.encode!(Enum.map(list, fn {id, slug} -> %{"id" => id, "slug" => slug} end))
    )
  end

  @doc "Everything the daemon must never change in a user's repository, except hm/ refs."
  def snapshot(path) do
    %{
      head: git(path, ["symbolic-ref", "-q", "HEAD"]),
      head_sha: git(path, ["rev-parse", "HEAD"]),
      status: git!(path, ["status", "--porcelain", "--untracked-files=all"]),
      index: git!(path, ["ls-files", "-s"]),
      cached: git!(path, ["diff", "--cached"]),
      diff: git!(path, ["diff"]),
      refs:
        path
        |> git!(["for-each-ref", "--format=%(refname) %(objectname)"])
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "refs/heads/hm/")),
      config: git!(path, ["config", "--local", "--list"]),
      worktrees: git!(path, ["worktree", "list", "--porcelain"]),
      files: files(path)
    }
  end

  defp files(path) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, :crypto.hash(:sha256, File.read!(&1))})
  end

  @doc "A bare cache for `app` whose origin is the user's repository, as preparation leaves it."
  def seed_cache(user, name \\ "app") do
    cache = HelmsmanDaemon.LocalRepos.cache_path(name)
    Paths.private_dir!(cache)
    git!(cache, ["init", "-q", "--bare"])
    git!(cache, ["remote", "add", "origin", user])

    git!(cache, [
      "config",
      "--replace-all",
      "remote.origin.fetch",
      "+refs/heads/*:refs/remotes/origin/*"
    ])

    cache
  end

  @doc """
  A git wrapper that logs every argv to `log` and pauses the first command
  containing `pause` until `<root>/pause.release` exists (`<root>/pause.ready`
  marks the pause).
  """
  def pausing_git(root, pause) do
    log = Path.join(root, "argv.log")
    wrapper = Path.join(root, "pausing-git")
    ready = Path.join(root, "pause.ready")
    release = Path.join(root, "pause.release")

    File.write!(wrapper, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{log}'
    case " $* " in
      *" #{pause} "*)
        if [ ! -f '#{ready}' ]; then
          touch '#{ready}'
          while [ ! -f '#{release}' ]; do sleep 0.01; done
        fi ;;
    esac
    exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(wrapper, 0o755)
    %{executable: wrapper, log: log, ready: ready, release: release}
  end

  @doc "Lines logged by `pausing_git/2` since `File.write!(log, \"\")`."
  def user_repo_access?(log),
    do:
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.any?(&(&1 =~ ~r/(^| )(push|fetch|ls-remote|upload-pack|receive-pack)( |$)/))

  def local_repo(branch \\ "hm/1/bos-1", rescues \\ []) do
    %HelmsmanProtocol.RunSpec.Repo{
      kind: :local,
      name: "app",
      base_branch: "main",
      branch: branch,
      rescue_branches: rescues
    }
  end
end

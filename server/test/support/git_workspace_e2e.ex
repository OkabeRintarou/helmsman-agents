defmodule Helmsman.GitWorkspaceE2E do
  @moduledoc "Local Git fixtures and barriers for git workspace E2E tests."

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions

  @doc "Creates a bare acme/app.git with an initial main commit."
  def create_repository(root) do
    bare = Path.join([root, "acme", "app.git"])
    seed = Path.join(root, "seed")
    File.mkdir_p!(Path.dirname(bare))
    File.mkdir_p!(seed)

    git!(root, ["init", "--bare", "--initial-branch=main", bare])
    git!(root, ["init", "--initial-branch=main", seed])
    git!(seed, ["config", "user.name", "Fixture"])
    git!(seed, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(seed, "README.md"), "fixture\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial main"])
    git!(seed, ["remote", "add", "origin", bare])
    git!(seed, ["push", "origin", "main"])
    git!(bare, ["symbolic-ref", "HEAD", "refs/heads/main"])

    %{bare: bare, seed: seed}
  end

  @doc "Adds and pushes a uniquely named file to a bare remote branch."
  def push_file(%{bare: bare}, branch, filename, contents) do
    root = Path.join(System.tmp_dir!(), "helmsman-git-push-#{unique_tag()}")
    clone = Path.join(root, "clone")
    File.mkdir_p!(root)

    try do
      git!(root, ["-c", "protocol.file.allow=always", "clone", "--branch", branch, bare, clone])
      git!(clone, ["config", "user.name", "External writer"])
      git!(clone, ["config", "user.email", "external@example.test"])
      File.write!(Path.join(clone, filename), contents)
      git!(clone, ["add", filename])
      git!(clone, ["commit", "-m", "external update"])
      git!(clone, ["push", "origin", "HEAD:refs/heads/#{branch}"])
      git!(bare, ["rev-parse", "refs/heads/#{branch}"]) |> String.trim()
    after
      File.rm_rf!(root)
    end
  end

  @doc "The commit at `branch` in a bare repository."
  def head(%{bare: bare}, branch),
    do: git!(bare, ["rev-parse", "refs/heads/#{branch}"]) |> String.trim()

  @doc "Whether a bare repository has a branch ref."
  def branch?(%{bare: bare}, branch) do
    {_, status} =
      System.cmd(
        "git",
        git_args(["--git-dir", bare, "show-ref", "--verify", "refs/heads/#{branch}"]),
        env: git_env(),
        stderr_to_stdout: true
      )

    status == 0
  end

  @doc "The commit count at `branch` in a bare repository."
  def commit_count(%{bare: bare}, branch),
    do:
      git!(bare, ["rev-list", "--count", "refs/heads/#{branch}"])
      |> String.trim()
      |> String.to_integer()

  @doc "The file contents at `path` in a remote branch."
  def show(%{bare: bare}, branch, path),
    do: git!(bare, ["show", "refs/heads/#{branch}:#{path}"])

  @doc "Installs a receive hook that rejects the first `count` pushes."
  def reject_first_pushes(%{bare: bare}, count) do
    hook = Path.join([bare, "hooks", "pre-receive"])
    marker = Path.join(Path.dirname(bare), "pre-receive-count")

    File.write!(
      hook,
      ~s"""
      #!/bin/sh
      marker=#{shell_quote(marker)}
      count=0
      [ ! -f "$marker" ] || count=$(cat "$marker")
      count=$((count + 1))
      printf '%s' "$count" > "$marker"
      if [ "$count" -le #{count} ]; then echo 'temporary receive rejection' >&2; exit 1; fi
      exit 0
      """
    )

    File.chmod!(hook, 0o755)
    %{hook: hook, marker: marker}
  end

  @doc "Creates a receive-pack wrapper that drops the daemon's client-side Git config."
  def receive_pack_wrapper(directory) do
    path = Path.join(directory, "receive-pack-wrapper")
    git_exec_path = git!(directory, ["--exec-path"]) |> String.trim()
    receive_pack = Path.join(git_exec_path, "git-receive-pack")

    File.write!(
      path,
      ~s"""
      #!/bin/sh
      unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
      for key in $(env | sed -n 's/^GIT_CONFIG_KEY_\\([0-9][0-9]*\\)=.*/\\1/p'); do
        unset "GIT_CONFIG_KEY_$key" "GIT_CONFIG_VALUE_$key"
      done
      export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
      exec #{shell_quote(receive_pack)} "$@"
      """
    )

    File.chmod!(path, 0o755)
    path
  end

  @doc "Atomically publishes a daemon IPC command and waits for its reply."
  def kill_run(port, home, name, run_id, timeout \\ 30_000) do
    directory = Path.join(home, "e2e-control")
    command = Path.join(directory, "#{name}.json")
    reply = Path.join(directory, "#{name}.reply.json")
    temporary = command <> ".tmp"

    File.write!(temporary, Jason.encode!(%{"op" => "kill_run", "run_id" => run_id}))
    File.rename!(temporary, command)

    Helmsman.DaemonE2E.wait_until(
      port,
      "daemon kill reply for run #{run_id}",
      fn ->
        case File.read(reply) do
          {:ok, body} -> Jason.decode!(body)
          _ -> nil
        end
      end,
      timeout
    )
  end

  @doc "Attaches a blocking handler to the real after-push telemetry event."
  def attach_after_push(test_pid, run_id) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:helmsman, :runs, :after_push],
        &__MODULE__.after_push/4,
        {test_pid, run_id}
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  @doc false
  def after_push(_event, _measurements, %{run_id: run_id}, {test_pid, run_id}) do
    send(test_pid, {:git_workspace_after_push, run_id, self()})

    receive do
      {:release_git_workspace_after_push, ^run_id} -> :ok
    after
      180_000 -> exit(:e2e_after_push_barrier_timeout)
    end
  end

  def after_push(_event, _measurements, _metadata, _config), do: :ok

  def release_after_push(channel_pid, run_id),
    do: send(channel_pid, {:release_git_workspace_after_push, run_id})

  @doc "Runs `git` and returns stdout, failing with stderr and the arguments."
  def git!(directory, args) do
    {output, status} = git(directory, args)
    assert status == 0, "git #{Enum.join(args, " ")} failed in #{directory}:\n#{output}"
    output
  end

  @doc "Runs `git` in the isolated environment; returns `{output, exit_status}`."
  def git(directory, args),
    do: System.cmd("git", git_args(args), cd: directory, env: git_env(), stderr_to_stdout: true)

  defp git_args(args),
    do:
      [
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "credential.helper=",
        "-c",
        "protocol.file.allow=always"
      ] ++ args

  defp git_env do
    deleted =
      for {name, _} <- System.get_env(),
          String.starts_with?(name, ["GIT_", "VSCODE_"]) or
            name in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"],
          do: {name, nil}

    deleted ++
      [
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp unique_tag, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end

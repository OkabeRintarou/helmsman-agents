defmodule HelmsmanDaemon.Git do
  @moduledoc "Isolated git commands; installation tokens travel only through askpass."
  alias HelmsmanDaemon.{Env, Exec, Paths}

  @prefix ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "gc.auto=0"]
  @network ["fetch", "push", "ls-remote"]
  @askpass """
  #!/bin/sh
  case "$1" in
    *Username*) printf '%s\\n' x-access-token ;;
    *) printf '%s\\n' "$HELMSMAN_GIT_TOKEN" ;;
  esac
  """

  def context(run_dir, token, opts \\ []) do
    %{run_dir: run_dir, token: token, opts: opts}
  end

  def write_askpass(context) do
    Paths.private_dir!(context.run_dir)
    path = Path.join(context.run_dir, "askpass")
    File.write!(path, @askpass)
    File.chmod!(path, 0o700)
    path
  end

  def command(args, cwd, context) do
    network? = Enum.any?(args, &(&1 in @network))
    executable = Keyword.get(context.opts, :executable, System.find_executable("git"))

    timeout =
      Keyword.get(context.opts, :command_timeout_ms, if(network?, do: 120_000, else: 30_000))

    timeout = remaining_timeout(context, timeout)
    env = environment(context, network?)

    {if(executable, do: [executable | @prefix ++ args], else: nil),
     [cd: cwd, env: [:clear | Enum.to_list(env)], timeout: timeout] ++
       Keyword.take(context.opts, [:on_start])}
  end

  @doc """
  Options for fetch / ls-remote / push against a user's local repository. The
  other side's settings travel in its own command line: git drops repository
  environment such as `GIT_CONFIG_PARAMETERS` for local transports.
  """
  def local_transport(context, :upload),
    do: ["--upload-pack=" <> remote_git(context) <> " -c core.hooksPath=/dev/null upload-pack"]

  def local_transport(context, :receive),
    do: [
      "--receive-pack=" <>
        remote_git(context) <>
        " -c receive.denyCurrentBranch=refuse -c core.hooksPath=/dev/null receive-pack"
    ]

  defp remote_git(context) do
    executable = Keyword.get(context.opts, :executable, System.find_executable("git")) || "git"
    "'" <> String.replace(executable, "'", "'\\''") <> "'"
  end

  def run(args, cwd, context) do
    case command(args, cwd, context) do
      {nil, _} -> {:error, {:missing, "git executable not found; git >= 2.30 is required"}}
      {argv, opts} -> sanitize_result(Exec.command(argv, opts), context)
    end
  end

  def check_version(context) do
    case run(["--version"], context.run_dir, context) do
      {:ok, output} -> parse_version(output)
      {:error, _} = error -> error
    end
  end

  defp parse_version(output) do
    case Regex.run(~r/git version (\d+)\.(\d+)/, output) do
      [_, major, minor] ->
        if {String.to_integer(major), String.to_integer(minor)} >= {2, 30},
          do: :ok,
          else: {:error, {:version, "git >= 2.30 is required; found #{String.trim(output)}"}}

      _ ->
        {:error, {:version, "could not determine git version; git >= 2.30 is required"}}
    end
  end

  def identity(name, server_url) do
    host = URI.parse(server_url).host || "localhost"
    email = String.replace(name, ~r/[^A-Za-z0-9._-]/, "-") <> "@agents." <> host

    %{
      "GIT_AUTHOR_NAME" => name,
      "GIT_COMMITTER_NAME" => name,
      "GIT_AUTHOR_EMAIL" => email,
      "GIT_COMMITTER_EMAIL" => email
    }
  end

  defp environment(context, network?) do
    base = Keyword.get(context.opts, :base_env, System.get_env())

    base
    |> Env.child()
    |> Map.merge(Keyword.get(context.opts, :identity, %{}))
    |> Map.merge(%{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "LC_ALL" => "C"
    })
    |> network_env(context, network?)
  end

  defp network_env(env, %{token: nil}, true), do: env

  defp network_env(env, context, true),
    do:
      Map.merge(env, %{
        "GIT_ASKPASS" => Path.join(context.run_dir, "askpass"),
        "HELMSMAN_GIT_TOKEN" => context.token
      })

  defp network_env(env, _context, false), do: env

  defp remaining_timeout(context, timeout) do
    case Keyword.get(context.opts, :deadline) do
      nil -> timeout
      deadline -> min(timeout, max(deadline - System.monotonic_time(:millisecond), 0))
    end
  end

  def classify(output) do
    cond do
      Regex.match?(
        ~r/Authentication failed|could not read Username|Invalid username or (?:password|token)|HTTP (?:Basic: Access denied|401|403)|returned error: (?:401|403)/i,
        output
      ) ->
        :authentication

      Regex.match?(~r/\[rejected\]|non-fast-forward|fetch first/i, output) ->
        :rejected

      checked_out?(output) ->
        :rejected

      true ->
        :other
    end
  end

  @doc "A local receive-pack refused to update a branch checked out in one of its worktrees."
  def checked_out?(output),
    do: Regex.match?(~r/\[remote rejected\][^\n]*\(branch is currently checked out\)/, output)

  def redact(output),
    do: Regex.replace(~r{([A-Za-z][A-Za-z0-9+.-]*://)[^\s/'"<>]*@}, output, "\\1")

  defp sanitize_result({:ok, output}, context), do: {:ok, sanitize(output, context)}

  defp sanitize_result({:error, {reason, output}}, context),
    do: {:error, {reason, sanitize(output, context)}}

  # `:redact` replaces machine-only text, such as a local repository's path,
  # in every output: it can reach run events and errors seen by members.
  defp sanitize(output, context) do
    output = redact(output)

    output =
      if context.token, do: String.replace(output, context.token, "[REDACTED]"), else: output

    context.opts
    |> Keyword.get(:redact, [])
    |> Enum.reduce(output, fn {text, label}, acc -> String.replace(acc, text, label) end)
  end
end

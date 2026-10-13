defmodule HelmsmanDaemon.GitHelpers do
  @moduledoc "Local-only git fixtures; even setup commands disable credential helpers."
  alias HelmsmanDaemon.{Git, GitWorkspace, Paths}
  import HelmsmanDaemon.Case, only: [spec: 1]

  def fixture(root) do
    remote = Path.join([root, "remote", "acme", "app.git"])
    seed = Path.join(root, "seed")
    File.mkdir_p!(remote)
    File.mkdir_p!(seed)

    git =
      Git.context(Paths.run(999), "fixture-token",
        identity:
          Git.identity("Fixture", "http://localhost")
          |> Map.put("GIT_CEILING_DIRECTORIES", Path.expand(root))
      )

    Git.write_askpass(git)
    git!(git, root, ["init", "--bare", remote])
    git!(git, seed, ["init", "-b", "main"])
    commit(git, seed, "base.txt", "base\n", "base")
    git!(git, seed, ["remote", "add", "origin", "file://" <> remote])
    git!(git, seed, ["push", "origin", "main"])
    %{remote: remote, seed: seed, git: git, url: "file://" <> remote}
  end

  def git!(git, cwd, args) do
    case Git.run(args, cwd, git) do
      {:ok, output} -> String.trim(output)
      result -> raise "fixture git #{inspect(args)} failed: #{inspect(result)}"
    end
  end

  def commit(git, cwd, filename, text, message) do
    File.write!(Path.join(cwd, filename), text)
    git!(git, cwd, ["add", "-A"])
    git!(git, cwd, ["commit", "-m", message])
    git!(git, cwd, ["rev-parse", "HEAD"])
  end

  def repo_spec(fixture, id \\ 1) do
    %{
      spec(id)
      | repo: %HelmsmanProtocol.RunSpec.Repo{
          github_repository_id: 123_456_789,
          clone_url: fixture.url,
          base_branch: "main",
          branch: "hm/1/bos-1",
          rescue_branches: [],
          git_token: "ghs_PRIVATE_INSTALL_TOKEN",
          git_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        }
    }
  end

  def prepare(spec, opts \\ []),
    do:
      GitWorkspace.prepare(
        spec,
        Paths.run(spec.run_id),
        Keyword.merge([allow_file_urls: true], opts)
      )

  def push(fixture, source, target),
    do: git!(fixture.git, fixture.seed, ["push", "origin", source <> ":refs/heads/" <> target])

  def receive_pack(fixture) do
    executable = System.find_executable("git")
    wrapper = Path.join(Path.dirname(fixture.seed), "receive-pack")

    File.write!(
      wrapper,
      "#!/bin/sh\nexec '#{executable}' -c credential.helper= -c core.hooksPath=hooks receive-pack \"$@\"\n"
    )

    File.chmod!(wrapper, 0o700)
    wrapper
  end
end

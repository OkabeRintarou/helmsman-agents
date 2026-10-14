defmodule HelmsmanDaemon.MixProject do
  use Mix.Project

  # Shared by protocol, server and daemon; release tags are v<VERSION>.
  @version "../VERSION" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :helmsman_daemon,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:credentials_lock] ++ Mix.compilers(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      releases: releases()
    ]
  end

  # Single-file binaries (Burrito 1.5: the wrapper execs the VM, so the service
  # manager's SIGTERM reaches it). Each target is built natively on its own
  # platform by ../scripts/build-daemon.sh, which runs `mix release` on the OTP
  # built by ../scripts/build-erts.sh; that same OTP is the custom ERTS of every
  # target, never Burrito's precompiled one.
  defp releases do
    [
      helmsman: [
        applications: [erlexec: :load],
        steps: [&check_erts/1, :assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x64: [os: :linux, cpu: :x86_64, custom_erts: erts()],
            linux_arm64: [os: :linux, cpu: :aarch64, custom_erts: erts()],
            macos_x64: [os: :darwin, cpu: :x86_64, custom_erts: erts()],
            macos_arm64: [os: :darwin, cpu: :aarch64, custom_erts: erts()]
          ]
        ]
      ]
    ]
  end

  defp erts, do: List.to_string(:code.root_dir())

  defp check_erts(release) do
    unless File.regular?(Path.join(erts(), ".helmsman-erts")) do
      Mix.raise(
        "Build the daemon binary with ../scripts/build-daemon.sh: the release must run on " <>
          "the OTP built by ../scripts/build-erts.sh, not #{erts()}"
      )
    end

    release
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {HelmsmanDaemon.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:helmsman_protocol, path: "../protocol"},
      {:slipstream, "~> 1.2"},
      # Started by HelmsmanDaemon.Exec.ensure_started/0 (after SHELL is set), so
      # `helmsman --version` works even where the port program cannot run.
      {:erlexec, "~> 2.5", runtime: false},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.5.0", only: :prod},
      {:plug, "~> 1.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [plt_local_path: "priv/plts", plt_add_apps: [:mix, :erlexec]]
  end

  # Check-only quality gate shared with CI; it never rewrites files.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end
end

defmodule Mix.Tasks.Compile.CredentialsLock do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    source = Path.expand("c_src/credentials_lock.c")
    output = Path.expand("priv/credentials_lock")
    manifest = Path.join(Mix.Project.manifest_path(), "compile.credentials_lock")

    signature =
      :crypto.hash(
        :sha256,
        File.read!(source) <>
          to_string(:erlang.system_info(:system_architecture)) <>
          to_string(:code.root_dir()) <> (System.get_env("CC") || "cc")
      )

    if File.regular?(output) and
         File.read(manifest) == {:ok, signature <> :crypto.hash(:sha256, File.read!(output))} do
      {:noop, []}
    else
      compiler = System.get_env("CC") || "cc"
      File.mkdir_p!(Path.dirname(output))
      temporary = output <> ".#{System.pid()}.tmp"

      {log, status} =
        System.cmd(
          compiler,
          ["-O2", "-Wall", "-Wextra", "-Werror", source, "-o", temporary],
          stderr_to_stdout: true
        )

      if status != 0 do
        File.rm(temporary)
        Mix.raise("credentials lock helper compilation failed: #{log}")
      end

      File.chmod!(temporary, 0o755)
      checksum = :crypto.hash(:sha256, File.read!(temporary))
      File.rename!(temporary, output)
      File.mkdir_p!(Path.dirname(manifest))
      File.write!(manifest, signature <> checksum)
      {:ok, []}
    end
  end
end

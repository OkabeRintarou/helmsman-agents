defmodule HelmsmanDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :helmsman_daemon,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :erlexec, :crypto],
      mod: {HelmsmanDaemon.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:helmsman_protocol, path: "../protocol"},
      {:slipstream, "~> 1.2"},
      {:erlexec, "~> 2.5"},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [plt_local_path: "priv/plts", plt_add_apps: [:mix]]
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

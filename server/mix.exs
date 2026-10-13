defmodule Helmsman.MixProject do
  use Mix.Project

  def project do
    [
      app: :helmsman,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_add_apps: [:mix] ++ if(Mix.env() == :test, do: [:ex_unit], else: [])
      ],
      # No line numbers in POT references, so `gettext.extract --check-up-to-date`
      # (precommit) only fails when messages change.
      gettext: [write_reference_line_numbers: false]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Helmsman.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:oban, "~> 2.20"},
      {:crontab, "~> 1.1"},
      {:tz, "~> 0.28"},
      {:cloak_ecto, "~> 1.3"},
      {:jose, "~> 1.11"},
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:lucide,
       github: "lucide-icons/lucide",
       tag: "1.55.0",
       sparse: "icons",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.3"},
      {:hammer, "~> 7.5"},
      {:req, "~> 0.5"},
      {:mdex, "~> 0.14"},
      {:lumis, "~> 0.10"},
      {:lumis_wasm_bundle_backend, "~> 0.1"},
      {:lumis_wasm_bundle_web, "~> 0.1"},
      {:lumis_wasm_bash, "~> 0.26"},
      {:lumis_wasm_comment, "~> 0.26"},
      {:lumis_wasm_diff, "~> 0.26"},
      {:lumis_wasm_dockerfile, "~> 0.26"},
      {:lumis_wasm_heex, "~> 0.26"},
      {:lumis_wasm_toml, "~> 0.26"},
      {:lumis_wasm_yaml, "~> 0.26"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:anubis_mcp, "~> 2.1.0"},
      {:open_api_spex, "~> 3.21"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:helmsman_protocol, path: "../protocol"},
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm ci"
      ],
      "assets.build": [
        "compile",
        "tailwind helmsman",
        "esbuild helmsman",
        "esbuild helmsman_mermaid"
      ],
      "assets.deploy": [
        "tailwind helmsman --minify",
        "esbuild helmsman --minify",
        "esbuild helmsman_mermaid",
        "phx.digest"
      ],
      # Check-only quality gate shared with CI; it never rewrites files.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        &check_gettext/1,
        "helmsman.check_ui_classes",
        "test"
      ]
    ]
  end

  # `gettext.extract --check-up-to-date` in a separate VM: it force-recompiles the
  # project, and doing that after this VM consolidated protocols leaves "already
  # consolidated" warnings (e.g. the derived Inspect of Accounts.User) in the compile
  # manifest, which fails the next `compile --warnings-as-errors`.
  defp check_gettext(_args) do
    {_, status} =
      System.cmd("mix", ["gettext.extract", "--check-up-to-date"],
        env: [{"MIX_ENV", to_string(Mix.env())}],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("gettext.extract --check-up-to-date failed")
  end
end

defmodule Helmsman.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  # Top-level boot boundary: the only domain-side module allowed to reach
  # the web and MCP layers, and only their startup exports (Endpoint,
  # Telemetry, HelmsmanMCP.Supervisor).
  use Boundary, top_level?: true, deps: [Helmsman, HelmsmanWeb, HelmsmanMCP]

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    warn_if_mailer_only_logs()

    children = [
      HelmsmanWeb.Telemetry,
      Helmsman.Repo,
      Helmsman.Vault,
      {Oban, Application.fetch_env!(:helmsman, Oban)},
      Helmsman.GitHub.Tokens,
      {DNSCluster, query: Application.get_env(:helmsman, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Helmsman.PubSub},
      Helmsman.Presence,
      {Helmsman.RateLimit, clean_period: :timer.minutes(1)},
      HelmsmanMCP.Supervisor,
      {Helmsman.McpServers.Check, []},
      # `add-autopilots` decision 5: reconcile the schedules once at boot.
      Supervisor.child_spec(
        {Task, fn -> if boot_sweep?(), do: Helmsman.Autopilots.sweep_soon() end},
        id: :autopilots_boot_sweep
      ),
      # Start to serve requests, typically the last entry
      HelmsmanWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Helmsman.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp boot_sweep?, do: Application.get_env(:helmsman, :autopilots_boot_sweep, true)

  defp warn_if_mailer_only_logs do
    if Application.get_env(:helmsman, Helmsman.Mailer)[:adapter] == Swoosh.Adapters.Logger do
      Logger.warning(
        "HELMSMAN_MAILER_ADAPTER=log: emails are not delivered; their full content, " <>
          "including login links, is written to the log"
      )
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HelmsmanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

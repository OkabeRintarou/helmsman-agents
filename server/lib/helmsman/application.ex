defmodule Helmsman.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  # Top-level boot boundary: the only domain-side module allowed to reach
  # the web layer, and only its startup exports (Endpoint, Telemetry).
  use Boundary, top_level?: true, deps: [Helmsman, HelmsmanWeb]

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HelmsmanWeb.Telemetry,
      Helmsman.Repo,
      {DNSCluster, query: Application.get_env(:helmsman, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Helmsman.PubSub},
      # Start a worker by calling: Helmsman.Worker.start_link(arg)
      # {Helmsman.Worker, arg},
      # Start to serve requests, typically the last entry
      HelmsmanWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Helmsman.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HelmsmanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule MediaAssist.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MediaAssistWeb.Telemetry,
      MediaAssist.Repo,
      MediaAssist.Vault,
      {Oban, Application.fetch_env!(:media_assist, Oban)},
      {DNSCluster, query: Application.get_env(:media_assist, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MediaAssist.PubSub},
      # Start a worker by calling: MediaAssist.Worker.start_link(arg)
      # {MediaAssist.Worker, arg},
      # Start to serve requests, typically the last entry
      MediaAssistWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MediaAssist.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MediaAssistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule Lovelace.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Lovelace.StageDesigner.Generation

  @impl true
  def start(_type, _args) do
    children = [
      LovelaceWeb.Telemetry,
      Lovelace.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:lovelace, :ecto_repos), skip: skip_migrations?()},
      # Persist the bundled default before static or live pages can be served.
      %{
        id: Lovelace.StageDesigner.DefaultScene,
        start: {Lovelace.StageDesigner.BundledScenes, :initialize, []}
      },
      {DNSCluster, query: Application.get_env(:lovelace, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lovelace.PubSub},
      Lovelace.Owner.Throttle,
      Lovelace.Mail.OAuth,
      Lovelace.Mail.ViewData,
      {Oban, Application.fetch_env!(:lovelace, Oban)},
      # Recover authorized jobs independently of new-generation startup opt-in.
      # One asynchronous reservation per application startup; paid work runs in Oban.
      %{
        id: Lovelace.StageDesigner.Startup,
        start:
          {Task, :start_link,
           [
             fn ->
               Generation.reconcile()
               Lovelace.StageDesigner.generate_on_startup(%{}, actor: %{role: :stage_designer})
             end
           ]},
        restart: :temporary
      },
      # Start to serve requests, typically the last entry
      LovelaceWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lovelace.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LovelaceWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end

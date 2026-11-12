defmodule Monolith.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Monolith.Security.Vault

  @impl true
  def start(_type, _args) do
    startup_id = make_ref()

    children =
      [
        MonolithWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:monolith, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Monolith.PubSub},
        Monolith.Owner.Throttle
      ] ++ protected_children(startup_id) ++ [Monolith.Security.Bootstrap, MonolithWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Monolith.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MonolithWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  if Mix.env() == :test do
    alias Monolith.Security.ProtectedSupervisor

    defp protected_children(startup_id) do
      if Vault.enabled?() do
        [{Vault, startup_id: startup_id}]
      else
        [
          Monolith.Repo,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:monolith, :ecto_repos), skip: skip_migrations?()}
        ] ++
          ProtectedSupervisor.runtime_children() ++
          [{Oban, Application.fetch_env!(:monolith, Oban)}]
      end
    end

    defp skip_migrations? do
      # By default, sqlite migrations are run when using a release
      System.get_env("RELEASE_NAME") == nil
    end
  else
    defp protected_children(startup_id), do: [{Vault, startup_id: startup_id}]
  end
end

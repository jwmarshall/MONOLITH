defmodule Lovelace.Security.ProtectedSupervisor do
  @moduledoc "Database and background processes whose lifetime is bounded by vault unlock."
  use Supervisor

  alias Lovelace.Security.{Database, LeaseGuard}
  alias Lovelace.StageDesigner

  def start_link(key, handle, guard) do
    Supervisor.start_link(__MODULE__, {Database.repo_options(key), handle, guard},
      name: __MODULE__
    )
  end

  @impl true
  def init({options, handle, guard}) do
    case LeaseGuard.protect(guard, self()) do
      :ok ->
        Supervisor.init(
          [{Lovelace.Security.RuntimeLease, handle}, {Lovelace.Repo, options}],
          strategy: :one_for_one
        )

      _ ->
        :ignore
    end
  end

  def runtime_children do
    [
      %{
        id: Lovelace.StageDesigner.DefaultScene,
        start: {Lovelace.StageDesigner.BundledScenes, :initialize, []}
      },
      Lovelace.Mail.OAuth,
      Lovelace.GitHub.Auth,
      Lovelace.Mail.ViewData,
      Lovelace.Mail.RequestOwners
    ]
  end

  def activate(supervisor) do
    Enum.reduce_while(runtime_children(), :ok, fn child, :ok ->
      case Supervisor.start_child(supervisor, child) do
        {:ok, _} -> {:cont, :ok}
        {:ok, _, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :background_unavailable}}
      end
    end)
  end

  # Called only in the manager's next mailbox turn, after it has installed the
  # admission epoch and can service the leases acquired by provider workers.
  def resume(supervisor, startup?) do
    with {:ok, _} <-
           Supervisor.start_child(supervisor, {Oban, Application.fetch_env!(:lovelace, Oban)}),
         {:ok, :scheduled} <- StageDesigner.schedule_recovery(actor: %{role: :stage_designer}) do
      # This Ash action only admits local durable intent plus its ID-only job.
      # The permanent attempt and job commit together; no provider work occurs here.
      if startup?, do: StageDesigner.generate_on_startup(%{}, actor: %{role: :stage_designer})
      :ok
    else
      _ -> {:error, :background_unavailable}
    end
  end
end

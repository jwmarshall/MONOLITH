defmodule Lovelace.Security.ProtectedSupervisor do
  @moduledoc "Database and background processes whose lifetime is bounded by vault unlock."
  use Supervisor

  alias Lovelace.Security.{Database, LeaseGuard}
  alias Lovelace.StageDesigner.Generation

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

  def activate(supervisor) do
    children = [
      %{
        id: Lovelace.StageDesigner.DefaultScene,
        start: {Lovelace.StageDesigner.BundledScenes, :initialize, []}
      },
      Lovelace.Mail.OAuth,
      Lovelace.Mail.ViewData
    ]

    Enum.reduce_while(children, :ok, fn child, :ok ->
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
           Supervisor.start_child(supervisor, {Oban, Application.fetch_env!(:lovelace, Oban)}) do
      case Supervisor.start_child(supervisor, %{
             id: Lovelace.StageDesigner.Startup,
             start: {Task, :start_link, [fn -> recover(startup?) end]},
             restart: :temporary
           }) do
        {:ok, _} -> :ok
        {:ok, _, _} -> :ok
        _ -> {:error, :background_unavailable}
      end
    end
  end

  defp recover(startup?) do
    Generation.reconcile()

    if startup?,
      do: Lovelace.StageDesigner.generate_on_startup(%{}, actor: %{role: :stage_designer})
  end
end

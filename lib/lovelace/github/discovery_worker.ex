defmodule Lovelace.GitHub.DiscoveryWorker do
  @moduledoc "Protected ID-only account-access discovery; durable slot claims prevent duplicate execution."
  use Oban.Worker, queue: :github, max_attempts: 1

  @impl true
  def perform(%Oban.Job{args: %{"connection_id" => id, "discovery_id" => request_id}}) do
    case Lovelace.GitHub.run_discovery(id, request_id, actor: %{role: :local_owner}) do
      {:ok, %{status: :failed}} -> {:error, :github_discovery_failed}
      {:ok, _} -> :ok
      _ -> {:error, :github_discovery_failed}
    end
  end
end

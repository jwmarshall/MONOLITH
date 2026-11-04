defmodule Lovelace.GitHub.PollWorker do
  @moduledoc "Durable installation-owner/generation refresh; no credentials in job arguments."
  use Oban.Worker,
    queue: :github,
    max_attempts: 1,
    unique: [
      period: 240,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"organization_id" => id, "generation" => generation}}) do
    case Lovelace.GitHub.poll(id, generation, actor: %{role: :local_owner}) do
      {:ok, _} -> :ok
      _ -> {:error, :github_unavailable}
    end
  end

  def enqueue(org) do
    %{organization_id: org.id, generation: org.generation} |> new() |> Oban.insert()
  end
end

defmodule Lovelace.Calendar.PollWorker do
  @moduledoc "Durable agenda polling carrying account/generation/revision identifiers only."
  use Oban.Worker,
    queue: :calendar,
    max_attempts: 1,
    unique: [
      period: 180,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{
        args: %{"account_id" => id, "generation" => generation, "revision" => revision}
      }) do
    case Lovelace.Calendar.poll(id, generation, revision,
           actor: %{role: :mail_service, account_id: id}
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :calendar_unavailable}
    end
  end

  def enqueue(state) do
    %{account_id: state.account_id, generation: state.generation, revision: state.revision}
    |> new()
    |> Oban.insert()
  end
end

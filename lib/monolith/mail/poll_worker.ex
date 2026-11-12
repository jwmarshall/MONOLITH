defmodule Monolith.Mail.PollWorker do
  @moduledoc "Durable, account/generation-scoped polling; never contains mail or credentials."
  use Oban.Worker,
    queue: :gmail,
    max_attempts: 3,
    unique: [
      period: 180,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"account_id" => id, "generation" => generation}}) do
    case Monolith.Mail.poll(id, generation, actor: %{role: :mail_service, account_id: id}) do
      {:ok, %{error: :rate_limited}} ->
        :ok

      {:ok, %{error: reason}} when reason in [:unavailable, :provider] ->
        {:error, :mail_unavailable}

      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :mail_unavailable}
    end
  end

  def enqueue(account) do
    %{account_id: account.id, generation: account.generation}
    |> new()
    |> Oban.insert()
  end
end

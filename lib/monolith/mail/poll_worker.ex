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
  def perform(%Oban.Job{args: %{"account_id" => id, "generation" => generation}} = job) do
    policy = Monolith.Caching.policy!(:gmail)
    account = Monolith.Mail.get_account!(id, actor: %{role: :local_owner})

    if account.generation == generation and (job.attempt > 1 or due?(account, policy)) do
      poll(id, generation)
    else
      :ok
    end
  end

  defp poll(id, generation) do
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

  @doc false
  def due?(%{status: :ready, last_error: nil, last_success_at: %DateTime{} = at}, policy) do
    DateTime.compare(DateTime.add(at, policy.refresh_seconds), DateTime.utc_now()) != :gt
  end

  def due?(%{status: :ready, next_poll_at: at}, _policy),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  def due?(_, _policy), do: false

  def enqueue(account) do
    %{account_id: account.id, generation: account.generation}
    |> new()
    |> Oban.insert()
  end
end

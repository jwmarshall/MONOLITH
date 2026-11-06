defmodule Lovelace.Mail.ReadWorker do
  @moduledoc "ID-only, supersedable mail reads; private inputs and outputs never enter Oban."
  use Oban.Worker,
    queue: :gmail,
    max_attempts: 2,
    unique: [
      period: 600,
      fields: [:args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Lovelace.Mail.perform_read(id, actor: %{role: :mail_read}) do
      {:ok, true} -> :ok
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

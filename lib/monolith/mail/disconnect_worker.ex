defmodule Monolith.Mail.DisconnectWorker do
  @moduledoc "Accepted cleanup survives browser exit; durable claims fence revocation replays."
  use Oban.Worker,
    queue: :gmail,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Monolith.Mail.finish_disconnect(id, actor: %{role: :mail_cleanup}) do
      {:ok, true} -> :ok
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

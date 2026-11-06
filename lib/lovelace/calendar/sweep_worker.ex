defmodule Lovelace.Calendar.SweepWorker do
  @moduledoc "Independent bounded Calendar recovery and expired-payload cleanup while unlocked."
  use Oban.Worker, queue: :calendar, max_attempts: 3, unique: [period: 50]

  @impl true
  def perform(%Oban.Job{}) do
    case Lovelace.Calendar.sweep(actor: %{role: :local_owner}) do
      {:ok, %{swept: true}} -> :ok
      _ -> {:error, :calendar_unavailable}
    end
  end
end

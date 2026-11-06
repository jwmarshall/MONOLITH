defmodule Lovelace.GitHub.SweepWorker do
  @moduledoc "Minute sweep resumes overdue installation-owner polling after restart or sleep."
  use Oban.Worker, queue: :github, max_attempts: 1, unique: [period: 50]
  alias Lovelace.GitHub.Polling

  @impl true
  def perform(_), do: Polling.sweep()
end

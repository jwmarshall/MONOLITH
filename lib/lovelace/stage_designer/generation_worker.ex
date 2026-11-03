defmodule Lovelace.StageDesigner.GenerationWorker do
  @moduledoc "ID-only scenery work. Submission's durable claim fences all Oban replays."
  use Oban.Worker,
    queue: :gemini,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], states: [:available, :scheduled, :retryable]]

  alias Lovelace.StageDesigner.Generation

  def enqueue(id, operation, delay \\ 0) do
    options = if delay > 0, do: [schedule_in: delay], else: []

    %{"id" => id, "operation" => Atom.to_string(operation)}
    |> new(options)
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{args: %{"id" => id, "operation" => operation}}) do
    case operation do
      "submit" -> Generation.perform(id, :submit)
      "poll" -> Generation.perform(id, :poll)
      "cleanup" -> Generation.perform(id, :cleanup)
      _ -> :ok
    end
  end
end

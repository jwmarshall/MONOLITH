defmodule Lovelace.ConnectionDiagnostics.Worker do
  @moduledoc "Protected, bounded local keychain inspection; never makes provider requests."
  use Oban.Worker, queue: :diagnostics, max_attempts: 1
  alias Lovelace.ConnectionDiagnostics.Operations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}),
    do: Operations.perform(id)

  def perform(_), do: :ok
end

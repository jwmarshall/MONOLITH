defmodule Lovelace.StageDesigner.RecoveryWorker do
  @moduledoc "Repairs authorized tracking jobs; never authorizes another generation."
  use Oban.Worker, queue: :gemini, max_attempts: 1

  alias Lovelace.StageDesigner.Generation

  @impl true
  def perform(_job), do: Generation.reconcile()
end

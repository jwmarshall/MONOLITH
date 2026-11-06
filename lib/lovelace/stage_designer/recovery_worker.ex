defmodule Lovelace.StageDesigner.RecoveryWorker do
  @moduledoc "Repairs authorized tracking jobs; never authorizes another generation."
  use Oban.Worker,
    queue: :gemini,
    max_attempts: 3,
    unique: [period: 30, fields: [:worker], states: [:available, :scheduled, :retryable]]

  alias Lovelace.Security.Vault
  alias Lovelace.StageDesigner

  @impl true
  def perform(_job) do
    case Vault.with_access(fn -> StageDesigner.recover(actor: %{role: :stage_designer}) end) do
      {:ok, :recovered} -> :ok
      {:error, reason} when reason in [:locked, :vault_unavailable] -> {:snooze, 1}
      _ -> {:error, :background_unavailable}
    end
  rescue
    _ -> {:error, :background_unavailable}
  catch
    _, _ -> {:error, :background_unavailable}
  end
end

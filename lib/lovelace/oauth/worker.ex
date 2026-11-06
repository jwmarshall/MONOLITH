defmodule Lovelace.OAuth.Worker do
  @moduledoc "Claims permanently before touching ephemeral one-use OAuth secrets."
  use Oban.Worker, queue: :oauth, max_attempts: 1
  alias Lovelace.OAuth.Exchange
  alias Lovelace.Security.Vault

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => id}, id: job_id}) do
    Vault.with_access(fn -> execute(id, job_id) end)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp execute(id, job_id) do
    case Exchange.get(id) do
      {:ok, %{status: :queued} = exchange} ->
        # Optimistic version check is the durable one-shot reservation. Rescue,
        # duplicate delivery and missing holders never authorize another call.
        case Exchange.record(exchange, %{status: :claimed, outcome: :unknown, job_id: job_id}) do
          {:ok, claimed} ->
            result = holder(claimed.provider).execute(id)
            success = match?({:ok, _}, result)

            Exchange.record(claimed, %{
              status: if(success, do: :completed, else: :failed),
              outcome: if(success, do: :connected, else: :reauthorize)
            })

          _ ->
            :ok
        end

      {:ok, %{status: :claimed}} ->
        # A duplicate may arrive while the original is still publishing. Never
        # overwrite its result or turn an uncertain claim back into permission.
        :ok

      _ ->
        :ok
    end
  end

  defp holder(:google), do: Lovelace.Mail.OAuth
  defp holder(:github), do: Lovelace.GitHub.Auth
end

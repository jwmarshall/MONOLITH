defmodule Monolith.OAuth do
  @moduledoc "Authorized admission of one-use Google and GitHub authorization exchanges."
  use Ash.Domain
  alias Monolith.OAuth.Exchange

  resources do
    resource Monolith.OAuth.Exchange

    resource Monolith.OAuth.Operation do
      define :exchange, action: :exchange, args: [:attempt_id, :provider]
    end
  end

  def await(id, holder, deadline \\ 180_000) do
    until = System.monotonic_time(:millisecond) + deadline
    await_result(id, holder, until)
  end

  defp await_result(id, holder, until) do
    case holder.result(id) do
      :pending ->
        if pending?(id) and System.monotonic_time(:millisecond) < until do
          Process.sleep(25)
          await_result(id, holder, until)
        else
          settled_result(id, holder)
        end

      result ->
        result
    end
  end

  defp settled_result(id, holder) do
    case holder.result(id) do
      :pending -> {:error, :unavailable}
      result -> result
    end
  end

  def pending?(id) do
    case Exchange.get(id) do
      {:ok, %{status: status, job_id: job_id}} when status in [:queued, :claimed] ->
        case Monolith.Repo.get(Oban.Job, job_id) do
          %{state: state} when state in ["available", "scheduled", "executing", "retryable"] ->
            true

          _ ->
            false
        end

      _ ->
        false
    end
  end
end

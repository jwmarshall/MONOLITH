defmodule Lovelace.Mail.SweepWorker do
  @moduledoc "Minute tick discovers overdue connections after restart or sleep; no full mailbox sync."
  use Oban.Worker, queue: :gmail, max_attempts: 3, unique: [period: 50]
  alias Lovelace.Mail.{Operations, PollWorker}

  @impl true
  def perform(_) do
    # Internal coordinator has no credentials and emits jobs containing only IDs.
    Lovelace.Mail.list_accounts!(actor: %{role: :local_owner})
    |> Enum.each(fn account ->
      actor = %{role: :mail_service, account_id: account.id}
      Operations.prune(account.id, actor)

      if account.status == :ready &&
           DateTime.compare(account.next_poll_at, DateTime.utc_now()) != :gt do
        PollWorker.enqueue(account)
      end
    end)

    :ok
  end
end

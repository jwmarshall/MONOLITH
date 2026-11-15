defmodule Monolith.Mail.SweepWorker do
  @moduledoc "Minute tick discovers overdue connections after restart or sleep; no full mailbox sync."
  use Oban.Worker, queue: :gmail, max_attempts: 3, unique: [period: 50]
  alias Monolith.Mail.{Operations, PollWorker, Reads}
  alias Monolith.Security.Vault

  @impl true
  def perform(_) do
    Vault.with_access(&sweep/0)
  end

  defp sweep do
    policy = Monolith.Caching.policy!(:gmail)

    # Internal coordinator has no credentials and emits jobs containing only IDs.
    Monolith.Mail.list_accounts!(actor: %{role: :local_owner})
    |> Enum.each(fn account ->
      actor = %{role: :mail_service, account_id: account.id}
      Operations.prune(account.id, actor, policy)

      if PollWorker.due?(account, policy) do
        PollWorker.enqueue(account)
      end
    end)

    Reads.prune()
    :ok
  end
end

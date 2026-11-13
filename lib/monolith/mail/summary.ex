defmodule Monolith.Mail.Summary do
  @moduledoc "Bounded, provider-free Gmail health and membership metadata for owner read models."
  use Ash.Resource, domain: Monolith.Mail, authorizers: [Ash.Policy.Authorizer]

  @account_limit 256
  @membership_limit 4_096
  @summary_fields [
    :id,
    :email,
    :status,
    :last_error,
    :inbox_unread_count,
    :inbox_unread_recent_count,
    :inbox_unread_at,
    :inbox_unread_error
  ]

  actions do
    action :home_summary, :map do
      run fn _input, context -> summary(context.actor) end
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end

  defp summary(actor) do
    with {:ok, accounts} <-
           Monolith.Mail.list_accounts(actor: actor, query: [limit: @account_limit + 1]),
         true <- length(accounts) <= @account_limit,
         {:ok, memberships} <-
           Monolith.Mail.list_workspace_accounts(
             actor: actor,
             query: [limit: @membership_limit + 1]
           ),
         true <- length(memberships) <= @membership_limit do
      by_id = Map.new(accounts, &{&1.id, &1})
      workspace_ids = Enum.group_by(memberships, & &1.account_id, & &1.workspace_id)

      health =
        memberships
        |> Enum.group_by(& &1.workspace_id, &Map.get(by_id, &1.account_id))
        |> Map.new(fn {workspace_id, attached} ->
          attached = Enum.reject(attached, &is_nil/1)

          problems =
            attached
            |> Enum.filter(&(&1.status != :ready || not is_nil(&1.last_error)))
            |> Enum.map(&Map.take(&1, [:id, :email, :status, :last_error]))

          {workspace_id, %{total: length(attached), problems: problems}}
        end)

      summaries =
        accounts
        |> Enum.reject(&(&1.status == :disconnected))
        |> Enum.map(fn account ->
          account
          |> Map.take(@summary_fields)
          |> Map.put(:workspace_ids, Map.get(workspace_ids, account.id, []))
        end)

      {:ok,
       %{
         accounts: summaries,
         workspace_health: health,
         subscription_ids: Enum.map(accounts, & &1.id)
       }}
    else
      _ -> {:error, "Gmail summary is unavailable."}
    end
  end
end

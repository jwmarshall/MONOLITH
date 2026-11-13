defmodule Monolith.Home.Summary do
  @moduledoc "Bounded Home composition; integration domains own health and membership policy."
  use Ash.Resource, domain: Monolith.Home, authorizers: [Ash.Policy.Authorizer]

  @workspace_limit 256

  actions do
    action :summary, :map do
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
    with {:ok, workspaces} <-
           Monolith.Workspaces.list_workspaces(
             actor: actor,
             query: [limit: @workspace_limit + 1]
           ),
         true <- length(workspaces) <= @workspace_limit do
      mail = Monolith.Mail.home_summary(actor: actor)
      github = Monolith.GitHub.home_summary(actor: actor)
      names = Map.new(workspaces, &{&1.id, &1.name})

      {:ok,
       %{
         workspaces: workspaces,
         accounts: accounts(mail, names),
         workspace_health: health(workspaces, mail, github),
         subscription_ids: subscription_ids(mail),
         accounts_error?: not match?({:ok, _}, mail)
       }}
    else
      _ -> {:error, "Workspace summary is unavailable."}
    end
  end

  defp accounts({:ok, %{accounts: accounts}}, names) do
    Enum.map(accounts, fn account ->
      labels =
        account.workspace_ids
        |> Enum.map(&Map.get(names, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      account |> Map.delete(:workspace_ids) |> Map.put(:workspaces, labels)
    end)
  end

  defp accounts(_, _names), do: []

  defp subscription_ids({:ok, %{subscription_ids: ids}}), do: ids
  defp subscription_ids(_), do: []

  defp health(workspaces, {:ok, mail}, {:ok, github}) do
    Map.new(workspaces, fn workspace ->
      mail = Map.get(mail.workspace_health, workspace.id, %{total: 0, problems: []})
      github = Map.get(github.workspace_health, workspace.id, %{total: 0, problems: []})

      {workspace.id,
       %{
         total: mail.total + github.total,
         google_accounts: mail.total,
         github_installations: github.total,
         problems: mail.problems ++ github.problems
       }}
    end)
  end

  defp health(workspaces, _mail, _github), do: Map.new(workspaces, &{&1.id, nil})
end

defmodule Lovelace.GitHub.Polling do
  @moduledoc "Installation snapshot admission, fenced publication and bounded cache freshness."
  import Lovelace.GitHub.Store
  import Lovelace.GitHub.Coordination, only: [state: 1]
  alias Lovelace.GitHub.{Connection, Credentials, Organization, PollWorker}
  alias Lovelace.Security.Vault
  @service %{role: :github_service}

  def poll(args) do
    case state(fn -> admit(args) end) do
      {:ok, claimed} -> poll_claim(claimed)
      _ -> {:ok, %{skipped: true}}
    end
  end

  def refresh(id) do
    case get(id) do
      %Organization{status: :ready} = org ->
        org = expire(org)
        if future?(org.cooldown_until), do: {:ok, metadata(org)}, else: enqueue_refresh(org)

      _ ->
        {:error, :unavailable}
    end
  end

  defp poll_claim(claimed) do
    with {:ok, token, credential_account} <- Credentials.access_credential(claimed.connection_id),
         {:ok, org, account} <- state(fn -> poll_identity(claimed) end),
         true <- account.generation == credential_account.generation do
      result = provider().installation_snapshot(token, owner_map(org))
      state(fn -> publish(org, account, result) end)
    else
      {:error, reason} -> state(fn -> fail_claim(claimed, reason) end)
      _ -> {:ok, %{skipped: true}}
    end
  end

  defp admit(args) do
    case get(args.organization_id) do
      %Organization{status: :ready, generation: generation} = org
      when generation == args.generation ->
        if future?(org.next_poll_at) or future?(org.cooldown_until) or future?(org.claimed_until) do
          {:error, :changed}
        else
          {:ok, update!(expire(org), %{claim_id: uuid(), claimed_until: later(120)})}
        end

      _ ->
        {:error, :changed}
    end
  end

  defp poll_identity(expected) do
    with %Organization{status: :ready} = org <- get(expected.id),
         true <- org.generation == expected.generation and org.claim_id == expected.claim_id,
         %Connection{status: :ready} = account <- connection(org.connection_id) do
      {:ok, org, account}
    else
      _ -> {:error, :changed}
    end
  end

  defp publish(expected, expected_account, result) do
    with {:ok, org, account} <- poll_identity(expected),
         true <- account.generation == expected_account.generation do
      attrs =
        case result do
          {:error, reason} when reason in [:reconnect, :denied, :expired] ->
            cleared(:reauthorization, reason)

          _ ->
            Map.merge(snapshot(result, org), %{claimed_until: nil, claim_id: nil})
        end

      current = update!(org, attrs)
      broadcast(org.id)
      {:ok, metadata(current)}
    else
      _ -> {:ok, %{skipped: true}}
    end
  end

  defp fail_claim(expected, reason) do
    case get(expected.id) do
      %Organization{status: :ready, generation: generation, claim_id: claim} = org
      when generation == expected.generation and claim == expected.claim_id and reason != :changed ->
        current =
          update!(
            org,
            Map.merge(snapshot({:error, reason}, org), %{claim_id: nil, claimed_until: nil})
          )

        broadcast(org.id)
        {:ok, metadata(current)}

      _ ->
        {:ok, %{skipped: true}}
    end
  end

  defp enqueue_refresh(org) do
    current = update!(org, %{next_poll_at: now()})

    case PollWorker.enqueue(current) do
      {:ok, _} -> {:ok, metadata(current)}
      _ -> {:error, :unavailable}
    end
  end

  defp snapshot({:ok, data}, _) do
    missing =
      []
      |> missing_snapshot_reason(data, :issues, "issues_unavailable")
      |> missing_snapshot_reason(data, :workflow_runs, "actions_unavailable")

    data =
      Map.merge(
        %{
          repositories: [],
          issues: [],
          workflow_runs: [],
          issue_count: nil,
          issues_truncated: true,
          actions_truncated: true
        },
        data
      )

    Map.take(data, [
      :pull_requests,
      :repositories,
      :issues,
      :workflow_runs,
      :issue_count,
      :issues_truncated,
      :actions_truncated,
      :truncated,
      :total_count,
      :partial_reasons
    ])
    |> Map.put(:partial_reasons, Enum.uniq(Map.get(data, :partial_reasons, []) ++ missing))
    |> Map.merge(%{
      fetched_at: now(),
      last_error: nil,
      next_poll_at: later(300),
      cooldown_until: nil
    })
  end

  defp snapshot({:error, reason}, previous) do
    error = safe_error(reason)

    previous
    |> cached_snapshot()
    |> Map.merge(%{
      fetched_at: if(previous, do: previous.fetched_at),
      last_error: error,
      next_poll_at: later(if(error == :rate_limited, do: 900, else: 300)),
      cooldown_until: if(error == :rate_limited, do: later(900))
    })
  end

  defp snapshot(_, previous), do: snapshot({:error, :provider}, previous)

  defp cached_snapshot(previous) do
    if previous && recent?(previous.fetched_at) do
      Map.take(previous, [
        :pull_requests,
        :repositories,
        :issues,
        :workflow_runs,
        :issue_count,
        :issues_truncated,
        :actions_truncated,
        :total_count,
        :truncated,
        :partial_reasons
      ])
    else
      %{
        pull_requests: [],
        repositories: [],
        issues: [],
        workflow_runs: [],
        issue_count: nil,
        issues_truncated: false,
        actions_truncated: false,
        total_count: nil,
        truncated: false,
        partial_reasons: []
      }
    end
  end

  defp missing_snapshot_reason(reasons, data, key, reason),
    do: if(Map.has_key?(data, key), do: reasons, else: [reason | reasons])

  def expire(%Organization{fetched_at: nil} = org), do: org

  def expire(org) do
    if not recent?(org.fetched_at) and
         (org.repositories != [] or org.pull_requests != [] or org.issues != [] or
            org.workflow_runs != [] or not is_nil(org.total_count) or not is_nil(org.issue_count)) do
      current =
        update!(org, %{
          pull_requests: [],
          repositories: [],
          issues: [],
          workflow_runs: [],
          issue_count: nil,
          issues_truncated: false,
          actions_truncated: false,
          total_count: nil,
          truncated: false,
          partial_reasons: [],
          last_error: org.last_error || :provider
        })

      broadcast(org.id)
      current
    else
      org
    end
  end

  def sweep do
    safely(fn ->
      Vault.with_access(fn ->
        Organization
        |> Ash.Query.for_read(:due, %{}, actor: @service)
        |> Ash.read!()
        |> Enum.each(&PollWorker.enqueue/1)

        :ok
      end)
    end)
  end
end

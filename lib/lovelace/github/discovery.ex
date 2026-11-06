defmodule Lovelace.GitHub.Discovery do
  @moduledoc "Bounded durable account-access discovery; credentials and HTTP belong to its protected job."
  import Lovelace.GitHub.Store
  import Lovelace.GitHub.Coordination, only: [state: 1]

  alias Lovelace.GitHub.{
    ClientCredentials,
    Connection,
    Credentials,
    DiscoveryWorker,
    Organization
  }

  alias Lovelace.Repo
  require Ash.Query
  @service %{role: :github_service}
  @active_jobs ["available", "scheduled", "executing", "retryable"]

  def admit(id) do
    state(fn ->
      case connection(id) do
        %Connection{status: :ready} = account -> admit_ready(observe(account))
        _ -> {:error, :reconnect}
      end
    end)
  end

  defp admit_ready(account) do
    if active_job?(account.discovery_job_id) do
      {:ok, public(account)}
    else
      reserve_ready(account)
    end
  end

  defp reserve_ready(account) do
    with {:ok, client} <- admission_client(),
         {:ok, owners} <- owner_fence(account.id),
         {:ok, operation} <-
           Ash.transact(Connection, fn -> reserve(account, client.generation, owners) end) do
      notify(account.id)
      {:ok, operation}
    end
  end

  defp admission_client do
    case ClientCredentials.current() do
      {:ok, client} -> {:ok, client}
      {:error, :configuration} -> {:error, :configuration}
      _ -> {:error, :keychain}
    end
  end

  defp reserve(account, client_generation, owners) do
    id = uuid()

    current =
      transition!(account, %{
        discovery_id: id,
        discovery_generation: account.generation,
        discovery_client_generation: client_generation,
        discovery_owner_fence: owners,
        discovery_status: :pending,
        discovery_error: nil
      })

    case DiscoveryWorker.new(%{connection_id: account.id, discovery_id: id}) |> Oban.insert() do
      {:ok, job} ->
        current |> transition!(%{discovery_job_id: job.id}) |> public()

      _ ->
        Ash.DataLayer.rollback(Connection, :unavailable)
    end
  end

  def run(id, request_id, discover) do
    case state(fn -> claim(id, request_id) end) do
      {:ok, claimed} ->
        result = safely(fn -> discover_with_credential(claimed, discover) end)
        state(fn -> finish(claimed, result) end)

      :skip ->
        {:ok, %{status: :superseded}}
    end
  end

  defp claim(id, request_id) do
    case connection(id) do
      %Connection{discovery_id: ^request_id, discovery_status: :pending} = account ->
        claim_current(account)

      _ ->
        :skip
    end
  end

  defp claim_current(account) do
    if current?(account) do
      {:ok, transition!(account, %{discovery_status: :running})}
    else
      finish_slot(account, :superseded, :reconnect)
      :skip
    end
  end

  defp discover_with_credential(claimed, discover) do
    with {:ok, token, credential_account} <-
           Credentials.access_credential(claimed.id, claimed.discovery_generation),
         {:ok, account} <- state(fn -> admit_credential(claimed, credential_account) end) do
      discover.(token, account)
    end
  end

  defp admit_credential(claimed, credential_account) do
    with %Connection{discovery_id: id, discovery_status: :running} = current <-
           connection(claimed.id),
         true <- id == claimed.discovery_id,
         true <- current.generation == credential_account.generation,
         true <- current.discovery_generation == claimed.discovery_generation,
         true <- client_current?(current),
         {:ok, owners} <- owner_fence(current.id),
         true <- owners == claimed.discovery_owner_fence do
      {:ok, transition!(current, %{discovery_generation: credential_account.generation})}
    else
      _ -> {:error, :reconnect}
    end
  end

  # Called under the same state exclusion immediately before installation writes/fencing.
  def current?(expected) do
    case connection(expected.id) do
      %Connection{status: :ready} = account ->
        same_request?(account, expected) and
          account.generation == expected.discovery_generation and
          client_current?(account) and owners_current?(account)

      _ ->
        false
    end
  end

  defp same_request?(account, expected) do
    account.discovery_id == expected.discovery_id and
      account.discovery_status in [:pending, :running]
  end

  defp client_current?(account) do
    case ClientCredentials.current() do
      {:ok, %{generation: generation}} -> generation == account.discovery_client_generation
      _ -> false
    end
  end

  defp owners_current?(account) do
    {:ok, owners} = owner_fence(account.id)
    owners == account.discovery_owner_fence
  end

  defp owner_fence(id) do
    digest = owner_digest(id, nil, :crypto.hash_init(:sha256))
    {:ok, %{"digest" => Base.encode16(digest, case: :lower)}}
  end

  # Include retained/disconnected owners: their removal revisions must still fence work.
  # Keyset traversal keeps each read and the retained digest state bounded without
  # confusing the provider's 500-current-installation limit with lifetime identities.
  defp owner_digest(id, after_id, context) do
    query = Organization |> Ash.Query.filter(connection_id == ^id)
    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query

    owners =
      query
      |> Ash.Query.for_read(:read, %{}, actor: @service)
      |> Ash.Query.select([:generation])
      |> Ash.Query.unset(:sort)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(128)
      |> Ash.read!()

    context =
      Enum.reduce(owners, context, fn owner, digest ->
        :crypto.hash_update(digest, [owner.id, owner.generation])
      end)

    if length(owners) < 128,
      do: :crypto.hash_final(context),
      else: owner_digest(id, List.last(owners).id, context)
  end

  defp finish(claimed, result) do
    case connection(claimed.id) do
      %Connection{discovery_id: id, discovery_status: :running} = account
      when id == claimed.discovery_id ->
        finish_result(account, result)

      _ ->
        {:ok, %{status: :superseded}}
    end
  end

  defp finish_result(account, {:ok, _}) do
    if account.generation == account.discovery_generation and client_current?(account),
      do: finish_slot(account, :succeeded, nil),
      else: finish_slot(account, :superseded, :reconnect)
  end

  defp finish_result(account, {:error, reason}),
    do: finish_slot(account, :failed, safe_error(reason))

  defp finish_result(account, _), do: finish_slot(account, :failed, :unavailable)

  defp finish_slot(account, status, error) do
    current = transition!(account, %{discovery_status: status, discovery_error: error})
    notify(account.id)
    {:ok, public(current)}
  end

  # Directory reads recover the durable outcome even if the view missed every event.
  # A killed/rescued one-shot job never repeats its credential rotation or HTTP claim.
  def observe(%Connection{discovery_status: status} = account)
      when status in [:pending, :running] do
    if active_job?(account.discovery_job_id) do
      account
    else
      current = transition!(account, %{discovery_status: :failed, discovery_error: :unavailable})
      notify(account.id)
      current
    end
  end

  def observe(account), do: account

  defp active_job?(nil), do: false

  defp active_job?(id) do
    case Repo.get(Oban.Job, id) do
      %Oban.Job{state: "executing", attempted_at: %DateTime{} = started} ->
        DateTime.diff(now(), started, :second) < 180

      %Oban.Job{state: status} ->
        status in @active_jobs

      _ ->
        false
    end
  end

  defp public(account) do
    %{
      id: account.discovery_id,
      connection_id: account.id,
      job_id: account.discovery_job_id,
      status: account.discovery_status,
      error: account.discovery_error
    }
  end
end

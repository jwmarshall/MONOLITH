defmodule Monolith.GitHub.Operations do
  @moduledoc "Ash-facing installation discovery, account authorization and workspace membership."
  use Ash.Resource.Actions.Implementation
  import Monolith.GitHub.Store
  import Monolith.GitHub.Coordination, only: [state: 1]

  alias Monolith.GitHub.{
    ClientCredentials,
    Connection,
    Credentials,
    Discovery,
    Error,
    Organization,
    Polling,
    WorkspaceOrganization
  }

  alias Monolith.Security.Vault
  @owner %{role: :local_owner}
  @service %{role: :github_service}
  @impl true
  def run(input, _, _context) do
    case safely(fn ->
           Vault.with_access(fn -> execute(input.action.name, input.arguments) end)
         end) do
      {:error, reason} -> {:error, Error.exception(reason: safe_error(reason))}
      result -> result
    end
  end

  def authorization_fence do
    Vault.with_access(fn -> state(fn -> generations() end) end)
  end

  # Auth supplies a synchronous callback that fences cancellation immediately before writes.
  # Never hold the domain lock while calling back into the protected Auth server.
  def authorize(session, bundle, commit \\ fn fun -> fun.() end, before \\ nil) do
    safely(fn -> authorize_session(session, bundle, commit, before) end)
  end

  defp authorize_session(session, bundle, commit, before) do
    with :ok <- verify_session(session),
         {:ok, client} <- ClientCredentials.current(),
         bundle = Map.put_new(bundle, :client_generation, client.generation),
         true <- bundle.client_generation == client.generation,
         {:ok, stored} <- Credentials.encode_bundle(bundle),
         before = before || authorization_fence(),
         {:ok, identity} <- provider().user(bundle.access_token),
         {:ok, owners} <- provider().installations(bundle.access_token),
         :ok <- validate_discovery(identity, owners) do
      commit_authorization(commit, session, identity, owners, stored, before)
    else
      {:error, reason} -> {:error, safe_error(reason)}
      _ -> {:error, :provider}
    end
  end

  defp commit_authorization(commit, session, identity, owners, stored, before) do
    commit.(fn ->
      state(fn -> authorize_unchanged(session, identity, owners, stored, before) end)
    end)
  end

  defp authorize_unchanged(session, identity, owners, stored, before) do
    with :ok <- verify_session(session),
         :ok <- Credentials.current_client_bundle(stored),
         :ok <- unchanged(before, identity.github_id, owners),
         :ok <- compatible_owners(identity.github_id, owners) do
      authorize_current(session, identity, owners, stored)
    end
  end

  defp execute(:directory, _) do
    state(fn ->
      organizations = Enum.map(organizations(), &Polling.expire/1)

      {:ok,
       %{
         organizations: organizations,
         memberships: memberships(),
         connections: Enum.map(connections(), &Discovery.observe/1)
       }}
    end)
  end

  defp execute(:home_summary, _) do
    state(fn ->
      with {:ok, organizations} <-
             summary_records(Organization, 1_000, [
               :login,
               :status,
               :last_error,
               :legacy_credential
             ]),
           {:ok, memberships} <-
             summary_records(WorkspaceOrganization, 10_000, [:workspace_id, :organization_id]) do
        {:ok, %{workspace_health: workspace_health(organizations, memberships)}}
      end
    end)
  end

  defp execute(action, args) when action in [:attach, :attach_repositories] do
    state(fn ->
      selected = if action == :attach, do: [], else: args.repository_ids

      with {:ok, %Monolith.Workspaces.Workspace{}} <-
             Monolith.Workspaces.get_workspace(args.workspace_id, actor: @owner),
           %Organization{status: :ready, connection_id: connection_id} = org <-
             get(args.organization_id),
           %Connection{status: :ready} <- connection(connection_id),
           true <- valid_selection?(Polling.expire(org), selected),
           {:ok, _} <- attach(args.workspace_id, args.organization_id, Enum.uniq(selected)) do
        broadcast(args.organization_id)
        {:ok, true}
      else
        _ -> {:error, :unavailable}
      end
    end)
  end

  defp execute(:detach, args) do
    state(fn ->
      remove_memberships(args.organization_id, args.workspace_id)
      broadcast(args.organization_id)
      {:ok, true}
    end)
  end

  defp execute(:disconnect, args) do
    state(fn -> disconnect_organization(args.organization_id) end)
  end

  defp execute(:disconnect_account, args) do
    state(fn -> Credentials.disconnect_account(args.connection_id) end)
  end

  defp execute(:refresh, args) do
    state(fn -> Polling.refresh(args.organization_id) end)
  end

  defp execute(:poll, args), do: Polling.poll(args)

  defp execute(:discover, args), do: Discovery.admit(args.connection_id)

  defp execute(:run_discovery, args) do
    Discovery.run(args.connection_id, args.discovery_id, fn token, account ->
      before = state(fn -> generations() end)
      discover_current(before, token, account)
    end)
  end

  defp disconnect_organization(id) do
    case get(id) do
      nil ->
        {:error, :unavailable}

      org ->
        {:ok, disconnected} =
          transact(fn ->
            current = update!(org, cleared(:disconnected, nil))
            remove_memberships(org.id)
            current
          end)

        # Also makes retained pre-App PAT items explicitly removable after migration/adoption.
        finish_delete(disconnected, vault().delete(org.id))
    end
  end

  defp discover_current(before, token, account) do
    with {:ok, identity} <- provider().user(token),
         true <- identity.github_id == account.github_id,
         {:ok, owners} <- provider().installations(token),
         :ok <- validate_discovery(identity, owners) do
      state(fn -> synchronize_discovery(before, account, owners) end)
    else
      {:error, reason} -> discovery_failure(account, reason)
      _ -> discovery_failure(account, :reconnect)
    end
  end

  defp synchronize_discovery(before, account, owners) do
    # A legitimate rotation may have changed only this connection's generation.
    expected = put_in(before, [:connections, account.github_id], stamp(account))

    with true <- Discovery.current?(account),
         :ok <- unchanged(expected, account.github_id, owners),
         %Connection{status: :ready, generation: generation} <- connection(account.id),
         true <- generation == account.generation,
         :ok <- compatible_owners(account.github_id, owners),
         {:ok, result} <- transact(fn -> synchronize_owners(account, owners) end) do
      notify(account.id)
      {:ok, %{connection: metadata(account), organizations: Enum.map(result, &metadata/1)}}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp authorize_current(session, identity, owners, stored) do
    previous = find_connection(identity.github_id)

    attrs = %{
      login: identity.login,
      generation: uuid(),
      status: :reauthorization,
      last_error: :reconnect
    }

    # Fence the previous credential before any keychain replacement. Failed persistence must
    # never leave an apparently usable account pointing at an uncertain token version.
    {:ok, account} =
      transact(fn ->
        account =
          if previous do
            transition!(previous, attrs)
          else
            Connection
            |> Ash.Changeset.for_create(
              :authorize,
              Map.merge(attrs, %{id: uuid(), github_id: identity.github_id}),
              actor: @service
            )
            |> Ash.create!()
          end

        fence_owners(account.id, :reauthorization, :reconnect)
        account
      end)

    with :ok <- put_token(account.id, stored),
         {:ok, result} <-
           transact(fn ->
             :ok = verify_session(session)
             ready = transition!(account, %{status: :ready, last_error: nil})
             orgs = synchronize_owners(ready, owners)
             %{connection: metadata(ready), organizations: Enum.map(orgs, &metadata/1)}
           end) do
      notify(account.id)
      {:ok, result}
    else
      {:error, reason} ->
        fence_connection(account.id, :reauthorization, safe_error(reason))
        {:error, safe_error(reason)}

      _ ->
        fence_connection(account.id, :reauthorization, :unavailable)
        {:error, :unavailable}
    end
  end

  defp synchronize_owners(account, owners) do
    ids = MapSet.new(owners, & &1.github_id)

    for org <- account_owners(account.id), not MapSet.member?(ids, org.github_id) do
      update!(org, cleared(:reauthorization, :reconnect))
    end

    Enum.map(owners, fn owner ->
      previous = find_identity(owner.github_id)

      attrs =
        Map.merge(cleared(:ready, nil), %{
          login: owner.login,
          owner_type: owner.owner_type,
          installation_id: owner.installation_id,
          connection_id: account.id,
          next_poll_at: now()
        })

      if previous do
        update!(previous, attrs)
      else
        Organization
        |> Ash.Changeset.for_create(
          :connect,
          Map.merge(attrs, %{id: uuid(), github_id: owner.github_id}),
          actor: @service
        )
        |> Ash.create!()
      end
    end)
  end

  defp discovery_failure(expected, reason) do
    error = safe_error(reason)

    state(fn ->
      if error in [:reconnect, :denied, :expired] and Discovery.current?(expected) do
        fence_connection(expected.id, :reauthorization, error)
      end

      {:error, error}
    end)
  end

  defp generations do
    %{
      connections: Map.new(connections(), &{&1.github_id, stamp(&1)}),
      organizations: Map.new(organizations(), &{&1.github_id, stamp(&1)})
    }
  end

  defp unchanged(before, github_id, owners) do
    account = find_connection(github_id)
    ids = MapSet.new(owners, & &1.github_id)

    relevant =
      Enum.filter(organizations(), fn org ->
        MapSet.member?(ids, org.github_id) or (account && org.connection_id == account.id)
      end)

    same_account = Map.get(before.connections, github_id) == stamp(account)
    same_owners = Enum.all?(relevant, &(Map.get(before.organizations, &1.github_id) == stamp(&1)))
    if same_account and same_owners, do: :ok, else: {:error, :unavailable}
  end

  defp stamp(nil), do: nil
  defp stamp(record), do: {record.id, record.generation}

  defp compatible_owners(github_id, owners) do
    allowed = Enum.all?(owners, &compatible_owner?(find_identity(&1.github_id), github_id))

    if allowed, do: :ok, else: {:error, :denied}
  end

  defp compatible_owner?(nil, _github_id), do: true
  defp compatible_owner?(%Organization{connection_id: nil}, _github_id), do: true

  defp compatible_owner?(org, github_id) do
    case connection(org.connection_id) do
      %Connection{github_id: ^github_id} -> true
      _ -> false
    end
  end

  defp validate_discovery(identity, owners) when is_list(owners) and length(owners) <= 500 do
    valid =
      valid_identity?(identity) and
        Enum.all?(owners, fn owner ->
          valid_identity?(owner) and owner[:owner_type] in [:user, :organization] and
            is_integer(owner[:installation_id]) and owner.installation_id > 0
        end)

    unique =
      length(Enum.uniq_by(owners, & &1.github_id)) == length(owners) and
        length(Enum.uniq_by(owners, & &1.installation_id)) == length(owners)

    if valid and unique, do: :ok, else: {:error, :provider}
  end

  defp validate_discovery(_, _), do: {:error, :provider}

  defp valid_identity?(value) when is_map(value) do
    is_binary(value[:github_id]) and byte_size(value.github_id) in 1..255 and
      is_binary(value[:login]) and
      Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/, value.login)
  end

  defp valid_identity?(_), do: false

  defp verify_session(session) do
    case Monolith.Owner.verify_session(session) do
      {:ok, _} -> :ok
      _ -> {:error, :denied}
    end
  end

  defp summary_records(resource, bound, fields) do
    records =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: @service)
      |> Ash.Query.select(fields)
      |> Ash.Query.limit(bound + 1)
      |> Ash.read!()

    if length(records) <= bound, do: {:ok, records}, else: {:error, :unavailable}
  end

  defp summary_health(organization) do
    problems =
      if organization.status == :ready and is_nil(organization.last_error),
        do: [],
        else: [organization]

    %{total: 1, problems: problems}
  end

  defp valid_selection?(_org, []), do: true

  defp valid_selection?(org, selected) do
    recent?(org.fetched_at) and
      Enum.all?(selected, fn id -> Enum.any?(org.repositories, &(&1["id"] == id)) end)
  end

  defp workspace_health(organizations, memberships) do
    by_id =
      organizations
      |> Enum.reject(
        &(&1.status == :disconnected and &1.last_error != :keychain and
            not &1.legacy_credential)
      )
      |> Map.new(
        &{&1.id,
         %{
           id: &1.id,
           email: "GitHub · " <> &1.login,
           status: &1.status,
           last_error: &1.last_error
         }}
      )

    Enum.reduce(memberships, %{}, fn membership, grouped ->
      add_workspace_health(
        grouped,
        membership.workspace_id,
        Map.get(by_id, membership.organization_id)
      )
    end)
  end

  defp add_workspace_health(grouped, _workspace_id, nil), do: grouped

  defp add_workspace_health(grouped, workspace_id, organization) do
    current = summary_health(organization)

    Map.update(grouped, workspace_id, current, fn previous ->
      %{total: previous.total + 1, problems: current.problems ++ previous.problems}
    end)
  end
end

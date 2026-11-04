defmodule Lovelace.GitHub.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  alias Lovelace.GitHub.{Connection, Error, Organization, PollWorker, WorkspaceOrganization}
  alias Lovelace.Security.Vault
  @owner %{role: :local_owner}
  @service %{role: :github_service}
  @resources [Connection, Organization, WorkspaceOrganization]

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
         {:ok, stored} <- encode_bundle(bundle),
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
         :ok <- unchanged(before, identity.github_id, owners),
         :ok <- compatible_owners(identity.github_id, owners) do
      authorize_current(session, identity, owners, stored)
    end
  end

  def access_token(connection_id) do
    case access_credential(connection_id) do
      {:ok, token, _account} -> {:ok, token}
      error -> error
    end
  end

  defp access_credential(connection_id) do
    safely(fn ->
      Vault.with_access(fn ->
        serialized_credential(connection_id)
      end)
    end)
  end

  defp serialized_credential(connection_id) do
    serial({:refresh, connection_id}, fn ->
      intent = state(fn -> token_intent(connection_id) end)

      case intent do
        {:ok, token, account} -> {:ok, token, account}
        {:rotate, connection, refresh} -> rotate(connection, refresh)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp execute(:directory, _) do
    state(fn ->
      organizations = Enum.map(organizations(), &expire/1)

      {:ok,
       %{organizations: organizations, memberships: memberships(), connections: connections()}}
    end)
  end

  defp execute(:attach, args) do
    state(fn ->
      with {:ok, %Lovelace.Workspaces.Workspace{}} <-
             Lovelace.Workspaces.get_workspace(args.workspace_id, actor: @owner),
           %Organization{status: :ready, connection_id: connection_id} <-
             get(args.organization_id),
           %Connection{status: :ready} <- connection(connection_id),
           {:ok, _} <- attach(args.workspace_id, args.organization_id) do
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
    state(fn -> disconnect_account(args.connection_id) end)
  end

  defp execute(:refresh, args) do
    state(fn -> refresh_organization(args.organization_id) end)
  end

  defp execute(:discover, args) do
    before = state(fn -> generations() end)

    with {:ok, token, account} <- access_credential(args.connection_id) do
      discover_current(before, token, account)
    end
  end

  defp execute(:poll, args) do
    case state(fn -> admit(args) end) do
      {:ok, claimed} -> poll_claim(claimed)
      _ -> {:ok, %{skipped: true}}
    end
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

  defp disconnect_account(id) do
    case connection(id) do
      nil ->
        {:error, :unavailable}

      account ->
        {:ok, disconnected} = transact(fn -> disconnect_account_records(account) end)
        finish_delete(disconnected, vault().delete(account.id))
    end
  end

  defp disconnect_account_records(account) do
    current = transition!(account, %{status: :disconnected, generation: uuid(), last_error: nil})

    for org <- account_owners(account.id) do
      update!(org, cleared(:disconnected, nil))
      remove_memberships(org.id)
    end

    current
  end

  defp refresh_organization(id) do
    case get(id) do
      %Organization{status: :ready} = org ->
        org = expire(org)
        if future?(org.cooldown_until), do: {:ok, metadata(org)}, else: enqueue_refresh(org)

      _ ->
        {:error, :unavailable}
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

    with :ok <- unchanged(expected, account.github_id, owners),
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

  defp poll_claim(claimed) do
    with {:ok, token, credential_account} <- access_credential(claimed.connection_id),
         {:ok, org, account} <- state(fn -> poll_identity(claimed) end),
         true <- account.generation == credential_account.generation do
      result = provider().pull_requests(token, owner_map(org))
      state(fn -> publish(org, account, result) end)
    else
      {:error, reason} -> state(fn -> fail_claim(claimed, reason) end)
      _ -> {:ok, %{skipped: true}}
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

  defp token_intent(id) do
    case connection(id) do
      %Connection{status: :ready} = account ->
        ready_token_intent(account)

      %Connection{status: :refreshing} ->
        fence_connection(id, :reauthorization, :reconnect)
        {:error, :reconnect}

      _ ->
        {:error, :reconnect}
    end
  end

  defp ready_token_intent(account) do
    case read_bundle(account.id) do
      {:ok, bundle} ->
        token_bundle_intent(account, bundle)

      _ ->
        fence_connection(account.id, :reauthorization, :keychain)
        {:error, :keychain}
    end
  end

  defp token_bundle_intent(account, bundle) do
    cond do
      bundle["refresh_expires_at"] <= unix() ->
        fence_connection(account.id, :reauthorization, :expired)
        {:error, :expired}

      bundle["expires_at"] > unix() + 60 ->
        {:ok, bundle["access_token"], account}

      true ->
        # Durable one-shot intent is committed BEFORE rotating HTTP, including crash paths.
        reserved =
          transition!(account, %{
            status: :refreshing,
            generation: uuid(),
            last_error: :reconnect
          })

        {:rotate, reserved, bundle["refresh_token"]}
    end
  end

  defp rotate(expected, refresh) do
    result =
      safely(fn ->
        with {:ok, client_id} <- client_id(),
             {:ok, bundle} <- provider().refresh_token(client_id, refresh),
             {:ok, stored} <- encode_bundle(bundle) do
          {:ok, bundle.access_token, stored}
        else
          {:error, reason} -> {:error, safe_error(reason)}
          _ -> {:error, :provider}
        end
      end)

    state(fn -> finish_rotation(expected, result) end)
  end

  defp finish_rotation(expected, result) do
    case connection(expected.id) do
      %Connection{status: :refreshing, generation: generation} = account
      when generation == expected.generation ->
        commit_rotation(account, result)

      _ ->
        {:error, :reconnect}
    end
  end

  defp commit_rotation(account, result) do
    with {:ok, token, stored} <- result,
         :ok <- put_token(account.id, stored) do
      current = transition!(account, %{status: :ready, last_error: nil})
      {:ok, token, current}
    else
      {:error, reason} ->
        fence_connection(account.id, :reauthorization, safe_error(reason))
        {:error, safe_error(reason)}
    end
  end

  defp discovery_failure(expected, reason) do
    error = safe_error(reason)

    state(fn ->
      case connection(expected.id) do
        %Connection{status: :ready, generation: generation}
        when generation == expected.generation and error in [:reconnect, :denied, :expired] ->
          fence_connection(expected.id, :reauthorization, error)

        _ ->
          :ok
      end

      {:error, error}
    end)
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

  defp fence_connection(id, status, reason) do
    case connection(id) do
      nil ->
        :ok

      account ->
        transact(fn ->
          transition!(account, %{status: status, generation: uuid(), last_error: reason})
          fence_owners(id, :reauthorization, reason)
        end)

        notify(id)
    end
  end

  defp fence_owners(id, status, reason),
    do: Enum.each(account_owners(id), &update!(&1, cleared(status, reason)))

  defp cleared(status, error) do
    %{
      generation: uuid(),
      status: status,
      pull_requests: [],
      fetched_at: nil,
      total_count: nil,
      last_error: error,
      truncated: false,
      partial_reasons: [],
      claim_id: nil,
      claimed_until: nil,
      cooldown_until: nil,
      next_poll_at: later(300)
    }
  end

  defp finish_delete(record, result) when result in [:ok, {:error, :not_found}] do
    record =
      case record do
        %Organization{} -> update!(record, %{legacy_credential: false, last_error: nil})
        %Connection{} -> transition!(record, %{last_error: nil})
      end

    notify_record(record)
    {:ok, metadata(record)}
  end

  defp finish_delete(record, _) do
    case record do
      %Connection{} -> transition!(record, %{last_error: :keychain})
      %Organization{} -> update!(record, %{last_error: :keychain})
    end

    notify_record(record)
    {:error, :keychain}
  end

  defp enqueue_refresh(org) do
    current = update!(org, %{next_poll_at: now()})

    case PollWorker.enqueue(current) do
      {:ok, _} -> {:ok, metadata(current)}
      _ -> {:error, :unavailable}
    end
  end

  defp snapshot({:ok, data}, _) do
    Map.take(data, [:pull_requests, :truncated, :total_count, :partial_reasons])
    |> Map.merge(%{
      fetched_at: now(),
      last_error: nil,
      next_poll_at: later(300),
      cooldown_until: nil
    })
  end

  defp snapshot({:error, reason}, previous) do
    error = safe_error(reason)
    fresh = previous && recent?(previous.fetched_at)

    %{
      pull_requests: if(fresh, do: previous.pull_requests, else: []),
      fetched_at: if(previous, do: previous.fetched_at),
      total_count: if(fresh, do: previous.total_count),
      truncated: if(fresh, do: previous.truncated, else: false),
      partial_reasons: if(fresh, do: previous.partial_reasons, else: []),
      last_error: error,
      next_poll_at: later(if(error == :rate_limited, do: 900, else: 300)),
      cooldown_until: if(error == :rate_limited, do: later(900))
    }
  end

  defp snapshot(_, previous), do: snapshot({:error, :provider}, previous)
  defp expire(%Organization{fetched_at: nil} = org), do: org

  defp expire(org) do
    if not recent?(org.fetched_at) and (org.pull_requests != [] or not is_nil(org.total_count)) do
      current =
        update!(org, %{
          pull_requests: [],
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

  defp encode_bundle(bundle) when is_map(bundle) do
    if valid_token?(bundle[:access_token]) and valid_token?(bundle[:refresh_token]) and
         is_integer(bundle[:expires_in]) and bundle.expires_in > 0 and
         is_integer(bundle[:refresh_token_expires_in]) and bundle.refresh_token_expires_in > 0 do
      {:ok,
       Jason.encode!(%{
         access_token: bundle.access_token,
         refresh_token: bundle.refresh_token,
         expires_at: unix() + bundle.expires_in,
         refresh_expires_at: unix() + bundle.refresh_token_expires_in
       })}
    else
      {:error, :provider}
    end
  end

  defp encode_bundle(_), do: {:error, :provider}

  defp read_bundle(id) do
    with {:ok, value} when is_binary(value) and byte_size(value) <= 16_384 <- vault().get(id),
         {:ok, bundle} when is_map(bundle) <- Jason.decode(value),
         true <- valid_token?(bundle["access_token"]) and valid_token?(bundle["refresh_token"]),
         true <- is_integer(bundle["expires_at"]) and is_integer(bundle["refresh_expires_at"]) do
      {:ok, bundle}
    else
      _ -> {:error, :keychain}
    end
  end

  defp valid_token?(token),
    do:
      is_binary(token) and byte_size(token) in 1..4096 and
        Regex.match?(~r/\A[A-Za-z0-9_\-.]+\z/, token)

  defp verify_session(session) do
    case Lovelace.Owner.verify_session(session) do
      {:ok, _} -> :ok
      _ -> {:error, :denied}
    end
  end

  defp client_id do
    case Application.get_env(:lovelace, :github, [])[:client_id] do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :configuration}
    end
  end

  defp organizations, do: read(Organization)
  defp connections, do: read(Connection)
  defp memberships, do: read(WorkspaceOrganization)

  defp read(resource),
    do: resource |> Ash.Query.for_read(:read, %{}, actor: @service) |> Ash.read!()

  defp get(nil), do: nil
  defp get(id), do: one(Organization, :id, id)
  defp connection(nil), do: nil
  defp connection(id), do: one(Connection, :id, id)
  defp find_identity(id), do: one(Organization, :github_id, id)
  defp find_connection(id), do: one(Connection, :github_id, id)

  defp one(resource, field, value) do
    resource
    |> Ash.Query.filter(^%{field => value})
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read_one!()
  end

  defp account_owners(id) do
    Organization
    |> Ash.Query.filter(connection_id == ^id)
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read!()
  end

  defp update!(org, attrs),
    do: org |> Ash.Changeset.for_update(:publish, attrs, actor: @service) |> Ash.update!()

  defp transition!(account, attrs),
    do: account |> Ash.Changeset.for_update(:transition, attrs, actor: @service) |> Ash.update!()

  defp attach(workspace, org) do
    WorkspaceOrganization
    |> Ash.Changeset.for_create(:attach, %{workspace_id: workspace, organization_id: org},
      actor: @service
    )
    |> Ash.create()
  end

  defp remove_memberships(org, workspace \\ nil) do
    query = WorkspaceOrganization |> Ash.Query.filter(organization_id == ^org)
    query = if workspace, do: Ash.Query.filter(query, workspace_id == ^workspace), else: query

    query
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read!()
    |> Enum.each(fn membership ->
      membership |> Ash.Changeset.for_destroy(:detach, %{}, actor: @service) |> Ash.destroy!()
    end)
  end

  defp transact(fun), do: Ash.transact(@resources, fun)

  defp put_token(id, value),
    do: if(vault().put(id, value) == :ok, do: :ok, else: {:error, :keychain})

  defp vault,
    do: Application.get_env(:lovelace, :github_keychain, Lovelace.Integrations.GitHub.Keychain)

  defp provider,
    do: Application.get_env(:lovelace, :github_provider, Lovelace.Integrations.GitHub)

  defp state(fun), do: serial(:state, fun)
  defp serial(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun, [node()])
  defp owner_map(org), do: Map.take(org, [:installation_id, :github_id, :login, :owner_type])

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Lovelace.PubSub, "github:" <> id, {:github_changed, id})

  defp notify(id) do
    Enum.each(account_owners(id), &broadcast(&1.id))
    Phoenix.PubSub.broadcast(Lovelace.PubSub, "github:directory", :github_directory_changed)
  end

  defp notify_record(%Connection{id: id}), do: notify(id)
  defp notify_record(%Organization{id: id}), do: broadcast(id)

  defp metadata(record),
    do:
      Map.take(record, [
        :id,
        :github_id,
        :login,
        :generation,
        :status,
        :last_error,
        :fetched_at,
        :next_poll_at,
        :connection_id,
        :owner_type,
        :installation_id
      ])

  defp uuid, do: Ash.UUID.generate()
  defp now, do: DateTime.utc_now()
  defp unix, do: System.system_time(:second)
  defp later(seconds), do: DateTime.add(now(), seconds, :second)
  defp future?(nil), do: false
  defp future?(time), do: DateTime.compare(time, now()) == :gt
  defp recent?(nil), do: false
  defp recent?(time), do: DateTime.diff(now(), time, :second) < 86_400

  defp safe_error(reason)
       when reason in [
              :unavailable,
              :provider,
              :rate_limited,
              :reconnect,
              :keychain,
              :configuration,
              :denied,
              :expired
            ],
       do: reason

  defp safe_error(_), do: :provider

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

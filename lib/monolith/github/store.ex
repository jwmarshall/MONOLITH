defmodule Monolith.GitHub.Store do
  @moduledoc false
  require Ash.Query
  alias Monolith.GitHub.{Connection, Organization, WorkspaceOrganization}
  @service %{role: :github_service}
  @resources [Connection, Organization, WorkspaceOrganization]

  def fence_connection(id, status, reason) do
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

  def fence_owners(id, status, reason),
    do: Enum.each(account_owners(id), &update!(&1, cleared(status, reason)))

  def cleared(status, error) do
    %{
      generation: uuid(),
      status: status,
      pull_requests: [],
      repositories: [],
      issues: [],
      workflow_runs: [],
      issue_count: nil,
      issues_truncated: false,
      actions_truncated: false,
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

  def finish_delete(record, result) when result in [:ok, {:error, :not_found}] do
    record =
      case record do
        %Organization{} -> update!(record, %{legacy_credential: false, last_error: nil})
        %Connection{} -> transition!(record, %{last_error: nil})
      end

    notify_record(record)
    {:ok, metadata(record)}
  end

  def finish_delete(record, _) do
    case record do
      %Connection{} -> transition!(record, %{last_error: :keychain})
      %Organization{} -> update!(record, %{last_error: :keychain})
    end

    notify_record(record)
    {:error, :keychain}
  end

  def organizations, do: read(Organization)
  def connections, do: read(Connection)
  def memberships, do: read(WorkspaceOrganization)

  def read(resource),
    do: resource |> Ash.Query.for_read(:read, %{}, actor: @service) |> Ash.read!()

  def get(nil), do: nil
  def get(id), do: one(Organization, :id, id)
  def connection(nil), do: nil
  def connection(id), do: one(Connection, :id, id)
  def find_identity(id), do: one(Organization, :github_id, id)
  def find_connection(id), do: one(Connection, :github_id, id)

  def one(resource, field, value) do
    resource
    |> Ash.Query.filter(^%{field => value})
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read_one!()
  end

  def account_owners(id) do
    Organization
    |> Ash.Query.filter(connection_id == ^id)
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read!()
  end

  def update!(org, attrs),
    do: org |> Ash.Changeset.for_update(:publish, attrs, actor: @service) |> Ash.update!()

  def transition!(account, attrs),
    do: account |> Ash.Changeset.for_update(:transition, attrs, actor: @service) |> Ash.update!()

  def attach(workspace, org, repository_ids) do
    WorkspaceOrganization
    |> Ash.Changeset.for_create(
      :attach,
      %{workspace_id: workspace, organization_id: org, repository_ids: repository_ids},
      actor: @service
    )
    |> Ash.create()
  end

  def remove_memberships(org, workspace \\ nil) do
    query = WorkspaceOrganization |> Ash.Query.filter(organization_id == ^org)
    query = if workspace, do: Ash.Query.filter(query, workspace_id == ^workspace), else: query

    query
    |> Ash.Query.for_read(:read, %{}, actor: @service)
    |> Ash.read!()
    |> Enum.each(fn membership ->
      membership |> Ash.Changeset.for_destroy(:detach, %{}, actor: @service) |> Ash.destroy!()
    end)
  end

  def transact(fun), do: Ash.transact(@resources, fun)

  def put_token(id, value),
    do: if(vault().put(id, value) == :ok, do: :ok, else: {:error, :keychain})

  def vault,
    do: Application.get_env(:monolith, :github_keychain, Monolith.Integrations.GitHub.Keychain)

  def provider,
    do: Application.get_env(:monolith, :github_provider, Monolith.Integrations.GitHub)

  def owner_map(org), do: Map.take(org, [:installation_id, :github_id, :login, :owner_type])

  def broadcast(id),
    do: Phoenix.PubSub.broadcast(Monolith.PubSub, "github:" <> id, {:github_changed, id})

  def notify(id) do
    Enum.each(account_owners(id), &broadcast(&1.id))
    Phoenix.PubSub.broadcast(Monolith.PubSub, "github:directory", :github_directory_changed)
  end

  def notify_record(%Connection{id: id}), do: notify(id)
  def notify_record(%Organization{id: id}), do: broadcast(id)

  def metadata(record),
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

  def uuid, do: Ash.UUID.generate()
  def now, do: DateTime.utc_now()
  def unix, do: System.system_time(:second)
  def later(seconds), do: DateTime.add(now(), seconds, :second)
  def future?(nil), do: false
  def future?(time), do: DateTime.compare(time, now()) == :gt
  def recent?(nil), do: false
  def recent?(time), do: DateTime.diff(now(), time, :second) < 86_400

  def safe_error(reason)
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

  def safe_error(_), do: :provider

  def safely(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

defmodule Lovelace.Calendar.Operation do
  @moduledoc "Owner-authorized agenda and catalog operations; catalog never reads cached events."
  use Ash.Resource, domain: Lovelace.Calendar, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :catalog, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Calendar.Operations
    end

    action :snapshot, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :from_iso, :string, allow_nil?: false, constraints: [max_length: 40]
      argument :to_iso, :string, allow_nil?: false, constraints: [max_length: 40]
      argument :local_date, :string, allow_nil?: false, constraints: [max_length: 10]
      run Lovelace.Calendar.Operations
    end

    action :prepare, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :from_iso, :string, allow_nil?: false, constraints: [max_length: 40]
      argument :to_iso, :string, allow_nil?: false, constraints: [max_length: 40]
      argument :local_date, :string, allow_nil?: false, constraints: [max_length: 10]
      argument :timezone, :string, allow_nil?: false, constraints: [max_length: 128]
      run Lovelace.Calendar.Operations
    end

    action :select_calendars, :map do
      argument :account_id, :uuid, allow_nil?: false

      argument :ids, {:array, :string},
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 20, items: [max_length: 1024]]

      run Lovelace.Calendar.Operations
    end

    action :refresh, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Calendar.Operations
    end

    action :poll, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :generation, :uuid, allow_nil?: false
      argument :revision, :uuid, allow_nil?: false
      run Lovelace.Calendar.Operations
    end

    action :sweep, :map do
      run Lovelace.Calendar.Operations
    end
  end

  policies do
    policy action([:catalog, :snapshot, :prepare, :select_calendars, :refresh, :sweep]) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end

    policy action(:poll) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
      authorize_if actor_attribute_equals(:role, :mail_service)
    end
  end
end

defmodule Lovelace.Owner.Credential do
  @moduledoc "The one local owner credential. Creation requires trusted terminal or paired browser setup."
  use Ash.Resource,
    domain: Lovelace.Owner,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "owner_credentials"
  end

  authentication do
    strategies do
      password :password do
        identity_field :id
        hashed_password_field :hashed_password
        hash_provider Lovelace.Owner.Password
        registration_enabled? false
        sign_in_tokens_enabled? false
        confirmation_required? false
      end
    end
  end

  actions do
    read :read do
      primary? true
    end

    read :sign_in_with_password do
      get? true

      argument :id, :string, allow_nil?: false

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false, max_length: 1024
      end

      prepare AshAuthentication.Strategy.Password.SignInPreparation
    end

    create :configure do
      accept []

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false, min_length: 12, max_length: 1024
      end

      change set_attribute(:id, "owner")
      change Lovelace.Owner.HashPassword
    end

    action :configured, :boolean do
      run {Lovelace.Owner.Actions, operation: :configured}
    end

    action :unlock, :string do
      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false, max_length: 1024
      end

      argument :client, :string do
        allow_nil? false
        sensitive? true
        constraints max_length: 128
      end

      run {Lovelace.Owner.Actions, operation: :unlock}
    end

    action :unlock_for_maintenance, :string do
      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false, max_length: 1024
      end

      run {Lovelace.Owner.Actions, operation: :unlock_for_maintenance}
    end
  end

  policies do
    policy action(:sign_in_with_password) do
      access_type :strict
      authorize_if AshAuthentication.Checks.AshAuthenticationInteraction
    end

    policy action(:configure) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :owner_setup)
    end

    policy action(:read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :owner_auth_service)
    end

    policy action(:unlock_for_maintenance) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :owner_setup)
    end

    policy action([:configured, :unlock]) do
      authorize_if always()
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints match: ~r/\Aowner\z/
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    create_timestamp :created_at
  end
end

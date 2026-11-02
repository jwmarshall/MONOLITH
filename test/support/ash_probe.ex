defmodule Lovelace.TestSupport.AshProbe do
  @moduledoc false
  use Ash.Resource,
    domain: Lovelace.TestSupport.AshDomain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    repo Lovelace.Repo
    table "ash_tooling_probes"
  end

  actions do
    defaults [:read, create: [:label]]
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? false
      public? true
    end
  end
end

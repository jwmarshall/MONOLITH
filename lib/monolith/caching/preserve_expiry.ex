defmodule Monolith.Caching.PreserveExpiry do
  @moduledoc false
  use Ash.Resource.Change

  alias Monolith.Caching
  alias Monolith.Caching.Preference

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:expired_before, ~U[1970-01-01 00:00:00.000000Z])
    |> Ash.Changeset.before_action(fn changeset ->
      integration = Ash.Changeset.get_attribute(changeset, :integration)
      previous = Ash.get!(Preference, integration, actor: context.actor, not_found_error?: false)
      policy = Caching.policy(integration, previous)
      now = DateTime.utc_now()
      retention = Ash.Changeset.get_attribute(changeset, :retention_hours)
      cutoff = Caching.cutoff(policy, now)
      shortened = DateTime.add(now, -retention * 3600)
      cutoff = if DateTime.compare(shortened, cutoff) == :gt, do: shortened, else: cutoff
      Ash.Changeset.force_change_attribute(changeset, :expired_before, cutoff)
    end)
  end
end

defmodule Monolith.Caching do
  @moduledoc "Application-wide cache policy, independent of connection identities and credentials."
  use Ash.Domain

  alias Monolith.Caching.Preference

  resources do
    resource Preference do
      define :preferences, action: :read

      define :save_preferences,
        action: :save_preferences,
        args: [:integration, :refresh_minutes, :retention_hours]
    end
  end

  @defaults %{gmail: {3, 168}, calendar: {3, 24}, github: {5, 24}}

  @doc "Reads current policy for bounded application work; never contacts a provider."
  def policy!(integration) when integration in [:gmail, :calendar, :github] do
    preference =
      Ash.get!(Preference, integration, actor: %{role: :cache_policy}, not_found_error?: false)

    policy(integration, preference)
  end

  @doc "Builds the effective policy from an owner-visible preference (or its absence)."
  def policy(integration, preference) when integration in [:gmail, :calendar, :github] do
    {refresh, retention} = Map.fetch!(@defaults, integration)
    refresh = if preference, do: preference.refresh_minutes, else: refresh
    retention = if preference, do: preference.retention_hours, else: retention

    %{
      integration: integration,
      refresh_minutes: refresh,
      retention_hours: retention,
      refresh_seconds: refresh * 60,
      retention_seconds: retention * 3600,
      expired_before: preference && preference.expired_before
    }
  end

  @doc "The oldest eligible observation, including the permanent expiration watermark."
  def cutoff(policy, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -policy.retention_seconds)

    if policy.expired_before && DateTime.compare(policy.expired_before, cutoff) == :gt,
      do: policy.expired_before,
      else: cutoff
  end

  def retained?(policy, at, now \\ DateTime.utc_now())

  def retained?(policy, %DateTime{} = at, now) do
    DateTime.compare(at, now) != :gt and DateTime.compare(at, cutoff(policy, now)) == :gt
  end

  def retained?(_, _, _), do: false

  def fresh?(policy, at, now \\ DateTime.utc_now()) do
    retained?(policy, at, now) and DateTime.diff(now, at) < policy.refresh_seconds
  end
end

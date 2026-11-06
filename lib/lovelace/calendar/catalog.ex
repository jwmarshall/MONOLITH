defmodule Lovelace.Calendar.Catalog do
  @moduledoc false
  alias Lovelace.Calendar.{Payload, Snapshot}
  alias Lovelace.Google.Access

  @fields [
    :account_id,
    :generation,
    :calendars,
    :selected_ids,
    :catalog_at,
    :truncated,
    :selection_truncated,
    :loading,
    :error,
    :cooldown_until
  ]

  def fields, do: @fields
  def selection_limit, do: 20

  def build(account, cached) do
    enabled = Snapshot.enabled?(account)
    cached = if Snapshot.current?(account, cached), do: cached
    fresh = fresh?(cached)
    cooldown = Access.cooldown?(account) or cooling?(cached)
    error = error(account, cached, cooldown)

    %{
      account_id: account && account.id,
      generation: account && account.generation,
      enabled: enabled,
      loading: loading?(cached, cooldown),
      error: error,
      catalog_at: cached && cached.catalog_at,
      catalog_fresh?: !!fresh,
      cooldown_until: cooldown_until(account, cached),
      available?: enabled and !!fresh and error != :reconnect,
      selection_limit: selection_limit()
    }
    |> Map.merge(content(cached, fresh))
  end

  def failure do
    build(nil, nil) |> Map.put(:error, :unavailable)
  end

  defp fresh?(nil), do: false
  defp fresh?(cached), do: Snapshot.recent?(cached.catalog_at)

  defp loading?(%{loading: true}, false), do: true
  defp loading?(_, _), do: false

  defp error(%{status: :reconnect}, _, _), do: :reconnect
  defp error(_, _, true), do: :rate_limited
  defp error(_, nil, _), do: nil
  defp error(_, cached, _), do: cached.error

  defp content(cached, true) do
    %{
      calendars: Enum.map(cached.calendars, &Payload.display(&1, [:id, :name])),
      selected_ids: cached.selected_ids,
      truncated: !!cached.truncated,
      selection_truncated: !!cached.selection_truncated
    }
  end

  defp content(_, _),
    do: %{calendars: [], selected_ids: [], truncated: false, selection_truncated: false}

  defp cooling?(%{cooldown_until: %DateTime{} = until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp cooling?(_), do: false

  defp cooldown_until(account, cached) do
    shared = if Access.cooldown?(account), do: account.next_poll_at
    calendar = if cooling?(cached), do: cached.cooldown_until

    case {shared, calendar} do
      {nil, until} -> until
      {until, nil} -> until
      {first, second} -> if DateTime.compare(first, second) == :gt, do: first, else: second
    end
  end
end

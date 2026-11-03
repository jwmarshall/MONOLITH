defmodule Lovelace.Calendar.Snapshot do
  @moduledoc false
  alias Lovelace.Calendar.{Payload, Window}
  alias Lovelace.Mail.Operations, as: MailOperations
  @event_fields [:id, :title, :start, :end, :all_day, :url, :calendar_id, :calendar_name]

  def build(account, state, window) do
    enabled = enabled?(account)
    state = if current?(account, state), do: state
    matching = state && Window.matches?(state, window)
    visible = if matching, do: state
    result = metadata(state, enabled)

    result =
      if enabled and MailOperations.cooldown?(account),
        do: %{result | error: :rate_limited, loading: false},
        else: result

    result
    |> Map.merge(content(visible))
    |> Map.merge(%{
      explicit_selection: !!(state && state.explicit_selection),
      pending: enabled and not visible_events?(visible),
      stale: stale?(visible, result.error),
      timezone: visible && visible.timezone,
      local_date: Date.to_iso8601(window.local_date)
    })
  end

  def failure do
    metadata(nil, false, :unavailable)
    |> Map.merge(content(nil))
    |> Map.merge(%{
      explicit_selection: false,
      pending: true,
      stale: false,
      timezone: nil,
      local_date: nil
    })
  end

  def metadata(state, enabled, error \\ nil) do
    %{
      enabled: enabled,
      loading: !!(state && state.loading),
      error: error || (state && state.error),
      revision: state && state.revision
    }
  end

  def enabled?(%{calendar_enabled: true, status: :ready}), do: true
  def enabled?(_), do: false

  def current?(account, state),
    do: enabled?(account) && state && state.generation == account.generation

  def recent?(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at) in 0..86_399
  def recent?(_), do: false
  defp visible_events?(nil), do: false
  defp visible_events?(state), do: recent?(state.fetched_at)

  defp stale?(state, error) do
    visible_events?(state) and
      (DateTime.diff(DateTime.utc_now(), state.fetched_at) >= 180 or not is_nil(error))
  end

  defp content(state) do
    Map.merge(event_content(state), calendar_content(state))
  end

  defp event_content(state) do
    if visible_events?(state) do
      %{
        events: Enum.map(state.events, &Payload.display(&1, @event_fields)),
        fetched_at: state.fetched_at,
        truncated: state.truncated
      }
    else
      %{events: [], fetched_at: nil, truncated: false}
    end
  end

  defp calendar_content(state) do
    if state && recent?(state.catalog_at) do
      %{
        calendars: Enum.map(state.calendars, &Payload.display(&1, [:id, :name, :selected])),
        selected_ids: state.selected_ids,
        selection_truncated: state.selection_truncated
      }
    else
      %{calendars: [], selected_ids: [], selection_truncated: false}
    end
  end
end

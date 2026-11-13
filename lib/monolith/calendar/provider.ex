defmodule Monolith.Calendar.Provider do
  @moduledoc """
  Application-owned contract for bounded, read-only Google Calendar pages.

  Each call returns one page of at most 100 calendars or expanded events. Adapters
  never follow another page: `truncated: true` means more provider data exists and
  the page must not be presented as complete. Calls have a finite whole-operation
  deadline (the Google adapter defaults to 15 seconds, capped at 30 seconds).
  Adapters return only the finite safe error atoms below, never HTTP bodies,
  exceptions, credentials or request data. These reads are safe to retry; no call
  grants consent, writes an event or submits an irreversible operation.

  Text is untrusted plain text. Event endpoints are ISO 8601 instants, or ISO dates
  for all-day events whose end is exclusive. Event links are nil or allowlisted
  HTTPS Google Calendar links. No descriptions, attendees, locations or remote
  assets enter the page. Calendar owns exact browser-day overlap filtering,
  selection (20), aggregate retention (500 events / 512 KiB), freshness timestamps,
  errors and cooldown policy. A returned page alone is not a fresh persisted
  observation; publication still requires the generation/day/revision fences.
  Credential refresh is the separate shared `Monolith.Google.Access` boundary.
  """

  @type error ::
          :locked
          | :timeout
          | :response_too_large
          | :transport_error
          | :invalid_configuration
          | :invalid_request
          | :invalid_response
          | :invalid_grant
          | :unauthorized
          | :forbidden
          | :insufficient_permissions
          | :not_found
          | :rate_limited
          | :provider_error
          | :unavailable
  @type failure :: {:error, error()}
  @type calendar :: %{id: binary(), name: binary(), selected: boolean()}
  @type event :: %{
          id: binary(),
          title: binary(),
          start: binary(),
          end: binary(),
          all_day: boolean(),
          url: binary() | nil
        }
  @type catalog_page :: %{calendars: [calendar()], truncated: boolean()}
  @type event_page :: %{events: [event()], truncated: boolean()}

  @callback calendars(access_token :: binary()) :: {:ok, catalog_page()} | failure()
  @callback events(
              access_token :: binary(),
              calendar_id :: binary(),
              from_iso :: binary(),
              to_iso :: binary()
            ) :: {:ok, event_page()} | failure()
end

defmodule LovelaceWeb.CalendarComponents do
  @moduledoc "Read-only, account-separated Calendar presentation from the local cache."
  use LovelaceWeb, :html

  attr :accounts, :list, required: true
  attr :window, :map, default: nil
  attr :refresh, :integer, default: 0
  attr :id, :string, default: "calendar-agenda"

  def agenda(assigns) do
    # Render-local only: never retain event/provider content in the LiveView socket.
    assigns = assign(assigns, :readouts, readouts(assigns.accounts, assigns.window))

    ~H"""
    <section id={@id} class="calendar-agenda" aria-labelledby={"#{@id}-heading"}>
      <header class="calendar-heading">
        <h3 id={"#{@id}-heading"} class="home-eyebrow">Today · Calendar</h3>
        <span class="calendar-muted">{timezone(@window)}</span>
      </header>
      <p class="calendar-muted">
        Local agenda · background polling while LOVELACE is running, not live updates.
      </p>
      <button
        :if={@accounts == []}
        type="button"
        class="workspace-action"
        phx-click="show_connections"
      >Enable Calendar in Connections →</button>
      <section
        :for={{account, snapshot} <- @readouts}
        id={"#{@id}-account-#{account.id}"}
        class="calendar-account"
        aria-labelledby={"#{@id}-identity-#{account.id}"}
        aria-busy={to_string(snapshot.loading)}
      >
        <header class="calendar-account-heading">
          <h4 id={"#{@id}-identity-#{account.id}"} class="calendar-identity">{account.email}</h4>
          <button
            :if={snapshot.enabled && @window}
            type="button"
            class="workspace-action"
            phx-click="calendar:refresh"
            phx-value-id={account.id}
            aria-label={"Refresh Calendar for #{account.email}"}
            disabled={snapshot.loading}
          >Refresh</button>
        </header>
        <div :if={!snapshot.enabled} class="calendar-message">
          <p>Calendar is not enabled for this account.</p>
          <button type="button" class="workspace-action" phx-click="show_connections">
            Enable in Connections →
          </button>
        </div>
        <div :if={snapshot.enabled}>
          <.status snapshot={snapshot} id={"#{@id}-status-#{account.id}"} />
          <button
            :if={snapshot.error == :reconnect}
            type="button"
            class="workspace-action"
            phx-click="show_connections"
          >Authorize Calendar again in Connections →</button>
          <p
            :if={successful?(snapshot) && snapshot.events == []}
            class="calendar-message"
          >
            {if snapshot.selected_ids == [],
              do: "No calendars selected in LOVELACE.",
              else: "No events today in the selected calendars."}
          </p>
          <ul :if={snapshot.events != []} class="calendar-events">
            <li
              :for={{event, index} <- Enum.with_index(snapshot.events)}
              class="calendar-event"
            >
              <span
                id={"#{@id}-time-#{account.id}-#{index}"}
                class="calendar-event-time"
                phx-hook="CalendarEventTime"
                data-start={iso(event.start)}
                data-end={iso(event.end)}
                data-all-day={to_string(event.all_day == true)}
              >
                <span
                  id={"#{@id}-time-text-#{account.id}-#{index}"}
                  data-calendar-time-text
                  phx-update="ignore"
                >{if event.all_day, do: "All day", else: "Local time loading…"}</span>
              </span>
              <div class="calendar-event-content">
                <p class="calendar-event-title">{present(event.title, "(Untitled event)")}</p>
                <p class="calendar-muted">{present(event.calendar_name, "Calendar")}</p>
              </div>
              <a
                :if={safe_google_url(event.url)}
                href={safe_google_url(event.url)}
                target="_blank"
                rel="noopener noreferrer"
                referrerpolicy="no-referrer"
                class="calendar-event-link"
                aria-label={"Open #{present(event.title, "untitled event")} in Google Calendar (new tab)"}
              >Google Calendar ↗</a>
            </li>
          </ul>
        </div>
      </section>
    </section>
    """
  end

  attr :accounts, :list, required: true
  attr :workspace_options, :list, required: true
  attr :window, :map, default: nil
  attr :refresh, :integer, default: 0
  attr :id, :string, default: "calendar-connections"

  def connections(assigns) do
    assigns = assign(assigns, :readouts, readouts(assigns.accounts, assigns.window))

    ~H"""
    <section id={@id} class="calendar-connections" aria-labelledby={"#{@id}-heading"}>
      <header class="calendar-heading">
        <h3 id={"#{@id}-heading"} class="mail-section-title">Calendar</h3>
        <p class="calendar-muted">Optional read-only access on an existing Google connection.</p>
      </header>
      <p :if={@accounts == []} class="calendar-message">
        Connect Gmail first to add Calendar to the same Google account.
      </p>
      <article
        :for={{account, snapshot} <- @readouts}
        id={"#{@id}-account-#{account.id}"}
        class="calendar-account"
        aria-labelledby={"#{@id}-identity-#{account.id}"}
      >
        <h4 id={"#{@id}-identity-#{account.id}"} class="calendar-identity">{account.email}</h4>
        <p class="calendar-muted">
          {if snapshot.enabled, do: "Calendar · read-only", else: "Calendar not enabled"}
        </p>
        <.authorize
          :if={!snapshot.enabled || snapshot.error == :reconnect}
          account={account}
          workspace_options={@workspace_options}
          id={@id}
          reconnect={snapshot.error == :reconnect}
        />
        <div :if={snapshot.enabled}>
          <.status snapshot={snapshot} id={"#{@id}-status-#{account.id}"} />
          <details
            :if={snapshot.calendars != []}
            id={"#{@id}-selection-#{account.id}"}
            class="calendar-selection"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Calendars shown in LOVELACE</summary>
            <.form
              for={to_form(%{}, as: nil)}
              id={"#{@id}-select-#{account.id}"}
              phx-submit="calendar:select"
            >
              <input type="hidden" name="account_id" value={account.id} />
              <%!-- An empty selection still submits a list; the handler discards the sentinel. --%>
              <input type="hidden" name="calendar_ids[]" value="" />
              <fieldset disabled={snapshot.loading || snapshot.error == :reconnect}>
                <legend>Choose up to 20 calendars for this account</legend>
                <p class="calendar-muted">
                  Google-selected calendars are used by default. Changes here affect only LOVELACE.
                  Uncheck all to show none.
                </p>
                <label :for={calendar <- snapshot.calendars} class="calendar-checkbox">
                  <input
                    type="checkbox"
                    name="calendar_ids[]"
                    value={calendar.id}
                    checked={calendar.id in snapshot.selected_ids}
                  />
                  <span>{present(calendar.name, "(Unnamed calendar)")}</span>
                </label>
                <button type="submit" class="workspace-action">Save calendar selection</button>
              </fieldset>
            </.form>
          </details>
          <p :if={snapshot.calendars == []} class="calendar-message">
            {if successful?(snapshot),
              do: "No calendars available for this account.",
              else: "Calendar list unavailable until a successful update."}
          </p>
          <button
            type="button"
            class="workspace-action"
            phx-click="calendar:refresh"
            phx-value-id={account.id}
            disabled={snapshot.loading || is_nil(@window)}
          >Refresh Calendar</button>
        </div>
      </article>
      <p id={"#{@id}-disconnect-help"} class="calendar-muted calendar-disconnect-help">
        Calendar shares this Google connection. There is no separate Calendar disconnect.
        Disconnect everywhere removes the shared connection from every workspace.
        <button
          type="button"
          class="workspace-action"
          phx-click="select_connection"
          phx-value-provider="gmail"
        >Manage Google connection in Gmail</button>
      </p>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :workspace_options, :list, required: true
  attr :id, :string, required: true
  attr :reconnect, :boolean, required: true

  defp authorize(assigns) do
    assigns =
      assign(assigns, :form, to_form(%{"workspace_id" => ""}, as: nil))

    ~H"""
    <.form
      for={@form}
      id={"#{@id}-authorize-#{@account.id}"}
      action="/oauth/google/start"
      method="post"
      class="calendar-authorize"
    >
      <input type="hidden" name="capability" value="calendar" />
      <input type="hidden" name="expected_account_id" value={@account.id} />
      <.input
        field={@form[:workspace_id]}
        id={"#{@id}-workspace-#{@account.id}"}
        type="select"
        label="Receiving workspace"
        options={@workspace_options}
        prompt="Choose workspace"
        class="connection-workspace-select"
        required
      />
      <button type="submit" class="workspace-action" disabled={@workspace_options == []}>
        {if @reconnect, do: "Authorize Calendar again", else: "Enable read-only Calendar"}
      </button>
      <p :if={@workspace_options == []} class="calendar-muted">Create a workspace first.</p>
    </.form>
    """
  end

  attr :snapshot, :map, required: true
  attr :id, :string, required: true

  defp status(assigns) do
    ~H"""
    <div id={@id} class="calendar-status" role="status" aria-live="polite">
      <p :if={@snapshot.loading}>Updating Calendar…</p>
      <p :if={@snapshot.pending && !@snapshot.loading && !@snapshot.error}>
        Waiting for today's Calendar update…
      </p>
      <p :if={@snapshot.error} class="calendar-warning">{error_text(@snapshot.error)}</p>
      <p :if={@snapshot.truncated} class="calendar-warning">
        Today's agenda is incomplete. Open Google Calendar for the full day.
      </p>
      <p :if={@snapshot.selection_truncated} class="calendar-warning">
        Not all calendars could be included. Choose up to 20 calendars in Connections.
      </p>
      <p :if={@snapshot.stale && !@snapshot.error} class="calendar-warning">
        Showing a previous local copy; it may no longer match Google Calendar.
      </p>
      <span
        :if={iso(@snapshot.fetched_at)}
        id={"#{@id}-observed"}
        phx-hook="ObservationTime"
        phx-update="ignore"
        data-observed-at={iso(@snapshot.fetched_at)}
        data-failed={to_string(not is_nil(@snapshot.error) || @snapshot.truncated || @snapshot.stale)}
      >Last checked · {iso(@snapshot.fetched_at)}</span>
      <p :if={!@snapshot.loading && !@snapshot.pending && !@snapshot.error && !@snapshot.fetched_at}>
        No successful Calendar update yet.
      </p>
    </div>
    """
  end

  defp readouts(accounts, window) do
    Enum.map(accounts, fn account -> {account, snapshot(account, window)} end)
  end

  defp snapshot(account, window) do
    enabled = Map.get(account, :calendar_enabled, false) == true

    result =
      if enabled && window do
        Lovelace.Calendar.snapshot(account.id, window.from, window.to, window.date,
          actor: %{role: :local_owner}
        )
      else
        %{enabled: enabled, loading: enabled}
      end

    snapshot = normalize_snapshot(result, enabled)

    if enabled && Map.get(account, :status) == :reconnect,
      do: %{snapshot | error: :reconnect, loading: false},
      else: snapshot
  end

  # Keep the local-cache API boundary here so backend shape changes stay localized.
  defp normalize_snapshot({:ok, data}, enabled), do: normalize_snapshot(data, enabled)

  defp normalize_snapshot({:error, error}, enabled),
    do: normalize_snapshot(%{error: error, loading: false}, enabled)

  defp normalize_snapshot(data, enabled) when is_map(data) do
    calendars = Map.get(data, :calendars, []) || []
    fetched_at = Map.get(data, :fetched_at)
    error = Map.get(data, :error)

    %{
      # Account capability remains enabled even when backend availability is false on reconnect.
      enabled: enabled,
      calendars: calendars,
      selected_ids:
        Map.get(data, :selected_ids) ||
          for(calendar <- calendars, Map.get(calendar, :selected, false), do: calendar.id),
      events: Enum.map(Map.get(data, :events, []) || [], &normalize_event/1),
      fetched_at: fetched_at,
      error: error,
      truncated: Map.get(data, :truncated, false) == true,
      selection_truncated: Map.get(data, :selection_truncated, false) == true,
      stale: Map.get(data, :stale, false) == true,
      pending: Map.get(data, :pending, is_nil(fetched_at)) == true,
      loading: Map.get(data, :loading, is_nil(fetched_at) && is_nil(error)) == true
    }
  end

  defp normalize_snapshot(_, enabled),
    do: normalize_snapshot(%{error: :unavailable, loading: false}, enabled)

  defp normalize_event(event) do
    Map.new([:id, :title, :start, :end, :all_day, :url, :calendar_id, :calendar_name], fn key ->
      {key, Map.get(event, key)}
    end)
  end

  defp successful?(snapshot),
    do:
      not is_nil(snapshot.fetched_at) && !snapshot.loading && !snapshot.pending &&
        is_nil(snapshot.error) && !snapshot.truncated && !snapshot.selection_truncated &&
        !snapshot.stale

  defp timezone(nil), do: "Waiting for browser timezone"
  defp timezone(window), do: Map.get(window, :timezone, "Browser local time")

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%Date{} = value), do: Date.to_iso8601(value)
  defp iso(value) when is_binary(value), do: value
  defp iso(_), do: nil

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _fallback), do: value

  defp safe_google_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443, path: path}
      when host in ["calendar.google.com", "www.google.com"] ->
        if is_binary(path) && (path == "/calendar" || String.starts_with?(path, "/calendar/")),
          do: value

      _ ->
        nil
    end
  end

  defp safe_google_url(_), do: nil

  defp error_text(:reconnect), do: "Calendar authorization needs reconnecting."
  defp error_text(:keychain), do: "Credential store unavailable. Check Connections."

  defp error_text(:rate_limited),
    do: "Google is rate limiting Calendar updates; polling will wait."

  defp error_text(:offline), do: "Calendar update unavailable while offline."

  defp error_text(:truncated),
    do: "Today's agenda is incomplete. Open Google Calendar for the full day."

  defp error_text(_),
    do: "Calendar update unavailable. Any displayed events are a previous local copy."
end

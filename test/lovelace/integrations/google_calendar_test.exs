defmodule Lovelace.Integrations.Google.CalendarTest do
  use ExUnit.Case, async: false
  alias Lovelace.Integrations.Google
  alias Lovelace.Integrations.Google.Calendar

  defmodule FakeTransport do
    @behaviour Google.Transport
    @impl true
    def request(request, options), do: Keyword.fetch!(options, :handler).(request)
  end

  @from "2026-11-01T00:00:00Z"
  @to "2026-11-08T00:00:00Z"

  setup do
    previous = Application.get_env(:lovelace, :gmail)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gmail, previous),
        else: Application.delete_env(:lovelace, :gmail)
    end)

    configure(fn _ -> flunk("unexpected request") end)
    :ok
  end

  test "calendar list is one bounded GET and returns only plain presentation data" do
    owner = self()

    configure(fn req ->
      send(owner, {:request, req})

      json(%{
        items: [
          %{
            id: "fake@example.invalid",
            summary: "<b>Work</b>",
            selected: true,
            description: "PRIVATE",
            location: "PRIVATE"
          }
        ],
        nextPageToken: "next"
      })
    end)

    assert {:ok,
            %{
              calendars: [%{id: "fake@example.invalid", name: "<b>Work</b>", selected: true}],
              truncated: true
            }} =
             Calendar.calendars("synthetic-access")

    assert_receive {:request, req}

    assert {req.method, req.host, URI.parse(req.path).path} ==
             {"GET", "www.googleapis.com", "/calendar/v3/users/me/calendarList"}

    assert {"authorization", "Bearer synthetic-access"} in req.headers
    assert URI.decode_query(URI.parse(req.path).query)["maxResults"] == "100"
    refute_receive {:request, _}
  end

  test "events encode the entire calendar ID, ask Google to expand recurrences, and omit private content" do
    owner = self()

    configure(fn req ->
      send(owner, {:request, req})
      json(%{items: [event(), %{"status" => "cancelled"}, all_day()], nextPageToken: "next"})
    end)

    assert {:ok, %{events: [timed, day], truncated: true}} =
             Calendar.events(
               "synthetic-access",
               "team+special/@group.calendar.google.com",
               @from,
               @to
             )

    assert timed == %{
             id: "evt1",
             title: "<b>Focus</b>",
             start: "2026-11-02T09:00:00+01:00",
             end: "2026-11-02T10:00:00+01:00",
             all_day: false,
             url: "https://calendar.google.com/calendar/event?eid=fake"
           }

    assert day.all_day
    assert day.start == "2026-11-03"
    assert day.end == "2026-11-04"
    assert_receive {:request, req}
    assert req.method == "GET"
    assert req.host == "www.googleapis.com"

    assert URI.parse(req.path).path ==
             "/calendar/v3/calendars/team%2Bspecial%2F%40group.calendar.google.com/events"

    query = URI.decode_query(URI.parse(req.path).query)

    assert Map.take(query, [
             "maxResults",
             "singleEvents",
             "orderBy",
             "showDeleted",
             "timeMin",
             "timeMax"
           ]) ==
             %{
               "maxResults" => "100",
               "singleEvents" => "true",
               "orderBy" => "startTime",
               "showDeleted" => "false",
               "timeMin" => @from,
               "timeMax" => @to
             }

    refute query["pageToken"]
    refute_receive {:request, _}
  end

  test "unsafe links are omitted, not followed; only exact Google Calendar HTTPS is retained" do
    for url <- [
          "http://calendar.google.com/x",
          "https://evil.invalid/x",
          "https://calendar.google.com.evil.invalid/x",
          "https://user@calendar.google.com/x",
          "https://calendar.google.com:444/x",
          "https://calendar.google.com:443/x",
          "https://www.google.com/arbitrary",
          "https://www.google.com/calendarish/event",
          "https://www.google.com/calendar/../arbitrary",
          "https://www.google.com/calendar/%2e%2e/arbitrary",
          "https://www.google.com/calendar/%5cevent",
          "https://www.google.com:444/calendar/event",
          "https://user@www.google.com/calendar/event",
          "https://www.google.com/calendar/event\n",
          "https://calendar.google.com:notaport/x",
          "//calendar.google.com/x",
          "https://calendar.google.com\\@evil.invalid/x",
          "javascript:alert(1)",
          "https://calendar.google.com/x\n",
          %{},
          nil
        ] do
      configure(fn _ -> json(%{items: [Map.put(event(), "htmlLink", url)]}) end)

      assert {:ok, %{events: [%{url: nil}], truncated: false}} =
               Calendar.events("synthetic-access", "primary", @from, @to)
    end

    for url <- [
          "https://calendar.google.com:443/calendar/event?eid=fake",
          "https://www.google.com/calendar/event?eid=fake",
          "https://www.google.com:443/calendar/event?eid=fake",
          "https://calendar.google.com/calendar",
          "https://www.google.com/calendar"
        ] do
      configure(fn _ -> json(%{items: [Map.put(event(), "htmlLink", url)]}) end)

      assert {:ok, %{events: [%{url: ^url}]}} =
               Calendar.events("synthetic-access", "primary", @from, @to)
    end
  end

  test "empty pages, truncated pages and item counts are honest and bounded" do
    configure(fn _ -> json(%{}) end)
    assert {:ok, %{calendars: [], truncated: false}} = Calendar.calendars("synthetic-access")

    assert {:ok, %{events: [], truncated: false}} =
             Calendar.events("synthetic-access", "primary", @from, @to)

    configure(fn _ -> json(%{items: List.duplicate(event(), 100), nextPageToken: "next"}) end)

    assert {:ok, %{events: events, truncated: true}} =
             Calendar.events("synthetic-access", "primary", @from, @to)

    assert length(events) == 100

    for body <- [
          %{items: List.duplicate(event(), 101)},
          %{items: %{}},
          %{nextPageToken: ""},
          %{nextPageToken: 1},
          %{items: [nil]}
        ] do
      configure(fn _ -> json(body) end)
      assert {:error, :invalid_response} = Calendar.calendars("synthetic-access")

      assert {:error, :invalid_response} =
               Calendar.events("synthetic-access", "primary", @from, @to)
    end
  end

  test "malformed event intervals, text and identifiers fail the whole page" do
    for bad <- [
          Map.put(event(), "start", %{"dateTime" => "not-a-date"}),
          Map.put(event(), "end", %{"date" => "2026-11-02"}),
          Map.put(event(), "end", %{"dateTime" => @from}),
          Map.put(event(), "start", %{"dateTime" => "2026-11-02T09:00:00"}),
          Map.put(all_day(), "end", %{"date" => "2026-11-03"}),
          Map.put(all_day(), "start", %{"date" => "2026-02-30"}),
          Map.put(event(), "id", ""),
          Map.put(event(), "summary", String.duplicate("x", 4097)),
          Map.put(event(), "status", "unknown")
        ] do
      configure(fn _ -> json(%{items: [bad]}) end)

      assert {:error, :invalid_response} =
               Calendar.events("synthetic-access", "primary", @from, @to)
    end
  end

  test "invalid requests never enter transport and errors never retry" do
    for {id, from, to} <- [
          {"..", @from, @to},
          {"", @from, @to},
          {"primary", @to, @from},
          {"primary", @from, @from},
          {"primary", "2026-11-01", @to},
          {"bad\n", @from, @to}
        ] do
      assert {:error, :invalid_request} = Calendar.events("synthetic-access", id, from, to)
    end

    assert {:error, :invalid_request} = Calendar.calendars("bad token")

    assert {:error, :invalid_request} =
             Google.calendar_get("synthetic-access", "//evil.invalid", [])

    owner = self()

    for {status, reason} <- [
          {401, :unauthorized},
          {403, :forbidden},
          {429, :rate_limited},
          {503, :provider_error}
        ] do
      configure(fn _ ->
        send(owner, :request)
        {:ok, %{status: status, headers: [], body: ""}}
      end)

      assert {:error, ^reason} = Calendar.events("synthetic-access", "primary", @from, @to)
      assert_receive :request
      refute_receive :request
    end
  end

  defp event do
    %{
      "id" => "evt1",
      "summary" => "<b>Focus</b>",
      "status" => "confirmed",
      "start" => %{"dateTime" => "2026-11-02T09:00:00+01:00"},
      "end" => %{"dateTime" => "2026-11-02T10:00:00+01:00"},
      "htmlLink" => "https://calendar.google.com/calendar/event?eid=fake",
      "description" => "PRIVATE",
      "attendees" => [%{"email" => "private@example.invalid"}],
      "location" => "PRIVATE",
      "image" => "https://evil.invalid/pixel"
    }
  end

  defp all_day do
    %{
      "id" => "evt2",
      "summary" => "Day",
      "start" => %{"date" => "2026-11-03"},
      "end" => %{"date" => "2026-11-04"}
    }
  end

  defp configure(handler) do
    Application.put_env(:lovelace, :gmail,
      transport: FakeTransport,
      transport_options: [handler: handler],
      timeout_ms: 1000
    )
  end

  defp json(data),
    do:
      {:ok,
       %{status: 200, headers: [{"content-type", "application/json"}], body: Jason.encode!(data)}}
end

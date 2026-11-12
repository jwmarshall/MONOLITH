defmodule Monolith.Calendar.PayloadTest do
  use ExUnit.Case, async: true
  alias Monolith.Calendar.Payload

  test "backend event payload retains only exact Google Calendar HTTPS links" do
    window = %{
      from_at: ~U[2026-11-01 00:00:00Z],
      to_at: ~U[2026-11-02 00:00:00Z],
      local_date: ~D[2026-11-01]
    }

    calendar = %{"id" => "primary", "name" => "Synthetic"}

    event = %{
      id: "event",
      title: "Focus",
      start: "2026-11-01T09:00:00Z",
      end: "2026-11-01T10:00:00Z",
      all_day: false
    }

    for url <- [
          "https://www.google.com/calendar/event?eid=synthetic",
          "https://calendar.google.com/calendar/event?eid=synthetic",
          "https://www.google.com:443/calendar/event?eid=synthetic",
          "https://calendar.google.com/calendar"
        ] do
      assert {:ok, [%{"url" => ^url}], false} =
               Payload.events(
                 %{events: [Map.put(event, :url, url)], truncated: false},
                 calendar,
                 window
               )
    end

    for url <- [
          "https://www.google.com/arbitrary",
          "https://calendar.google.com:443/x",
          "https://www.google.com/calendarish/event",
          "http://www.google.com/calendar/event",
          "https://www.google.com:444/calendar/event",
          "https://user@www.google.com/calendar/event",
          "https://www.google.com.evil.invalid/calendar/event",
          "https://www.google.com/calendar/event\n",
          "https://www.google.com/calendar\\event",
          "https://www.google.com/calendar/../arbitrary",
          "https://www.google.com/calendar/%2e%2e/arbitrary",
          "https://www.google.com/calendar/%5cevent",
          "https://www.google.com:bad/calendar/event",
          "//www.google.com/calendar/event",
          nil
        ] do
      assert {:ok, [%{"url" => nil}], false} =
               Payload.events(
                 %{events: [Map.put(event, :url, url)], truncated: false},
                 calendar,
                 window
               )
    end
  end
end

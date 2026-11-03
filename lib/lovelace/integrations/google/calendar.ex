defmodule Lovelace.Integrations.Google.Calendar do
  @moduledoc """
  Bounded, read-only Calendar pages. Recurrences are expanded by Google, never locally.
  No descriptions, attendees, locations or remote assets leave this boundary.
  Pages stop at 100 items and report truncation without following pagination.
  All-day end dates retain Google's exclusive-end semantics. Text is untrusted plain text.
  """

  alias Lovelace.Integrations.Google

  @spec calendars(binary()) ::
          {:ok, %{calendars: [map()], truncated: boolean()}} | Google.failure()
  def calendars(token) do
    query = [
      {"maxResults", "100"},
      {"fields", "items(id,summary,selected),nextPageToken"}
    ]

    with {:ok, data} <- Google.calendar_get(token, "/users/me/calendarList", query),
         {:ok, items, truncated} <- page(data),
         {:ok, calendars} <- parse_items(items, &calendar/1) do
      {:ok, %{calendars: calendars, truncated: truncated}}
    end
  end

  @spec events(binary(), binary(), binary(), binary()) ::
          {:ok, %{events: [map()], truncated: boolean()}} | Google.failure()
  def events(token, calendar_id, from_iso, to_iso) do
    with true <- identifier?(calendar_id),
         {:ok, from} <- timestamp(from_iso),
         {:ok, to} <- timestamp(to_iso),
         :lt <- DateTime.compare(from, to) do
      path = "/calendars/" <> URI.encode(calendar_id, &URI.char_unreserved?/1) <> "/events"

      query = [
        {"maxResults", "100"},
        {"singleEvents", "true"},
        {"orderBy", "startTime"},
        {"showDeleted", "false"},
        {"timeMin", from_iso},
        {"timeMax", to_iso},
        {"fields",
         "items(id,summary,start(date,dateTime),end(date,dateTime),status,htmlLink),nextPageToken"}
      ]

      with {:ok, data} <- Google.calendar_get(token, path, query),
           {:ok, items, truncated} <- page(data),
           {:ok, events} <- parse_items(items, &event/1) do
        {:ok, %{events: events, truncated: truncated}}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp page(data) when is_map(data) do
    items = Map.get(data, "items", [])
    next = Map.get(data, "nextPageToken")

    if is_list(items) and length(items) <= 100 and
         (is_nil(next) or text?(next, 4096, false)) do
      {:ok, items, not is_nil(next)}
    else
      {:error, :invalid_response}
    end
  end

  defp page(_), do: {:error, :invalid_response}

  defp parse_items(items, parser) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parser.(item) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        :omit -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp calendar(%{"id" => id} = data) do
    name = Map.get(data, "summary", id)
    selected = Map.get(data, "selected", false)

    if identifier?(id) and text?(name, 1024) and is_boolean(selected),
      do: {:ok, %{id: id, name: name, selected: selected}},
      else: {:error, :invalid_response}
  end

  defp calendar(_), do: {:error, :invalid_response}

  defp event(%{"status" => "cancelled"}), do: :omit

  defp event(%{"id" => id, "start" => start, "end" => ending} = data) do
    title = Map.get(data, "summary", "(Untitled event)")

    with true <- identifier?(id) and text?(title, 4096),
         true <- Map.get(data, "status") in [nil, "confirmed", "tentative"],
         {:ok, start_value, end_value, all_day} <- interval(start, ending) do
      {:ok,
       %{
         id: id,
         title: title,
         start: start_value,
         end: end_value,
         all_day: all_day,
         url: safe_url(Map.get(data, "htmlLink"))
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp event(_), do: {:error, :invalid_response}

  defp interval(%{"date" => start} = first, %{"date" => ending} = last) do
    with false <- Map.has_key?(first, "dateTime") or Map.has_key?(last, "dateTime"),
         true <- text?(start, 10, false) and text?(ending, 10, false),
         {:ok, from} <- Date.from_iso8601(start),
         {:ok, to} <- Date.from_iso8601(ending),
         :lt <- Date.compare(from, to) do
      {:ok, start, ending, true}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp interval(%{"dateTime" => start} = first, %{"dateTime" => ending} = last) do
    with false <- Map.has_key?(first, "date") or Map.has_key?(last, "date"),
         {:ok, from} <- timestamp(start),
         {:ok, to} <- timestamp(ending),
         :lt <- DateTime.compare(from, to) do
      {:ok, start, ending, false}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp interval(_, _), do: {:error, :invalid_response}

  defp timestamp(value) do
    if text?(value, 64, false) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _} -> {:ok, datetime}
        _ -> {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp safe_url(value) when is_binary(value) do
    with true <- text?(value, 4096, false) and not Regex.match?(~r/[\s\\\x00-\x1F\x7F]/u, value),
         %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           port: 443,
           authority: authority,
           path: path
         }
         when host in ["calendar.google.com", "www.google.com"] <- URI.parse(value),
         true <- authority in [host, host <> ":443"] and calendar_path?(path) do
      value
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_url(_), do: nil

  defp calendar_path?(path) when is_binary(path) do
    decoded = URI.decode(path)

    (path == "/calendar" or String.starts_with?(path, "/calendar/")) and
      not Regex.match?(~r/[\s\\\x00-\x1F\x7F]/u, decoded) and
      not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."]))
  end

  defp calendar_path?(_), do: false

  defp identifier?(value),
    do:
      text?(value, 1024, false) and value not in [".", ".."] and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, value)

  defp text?(value, max, empty \\ true),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= max and
        (empty or byte_size(value) > 0)
end

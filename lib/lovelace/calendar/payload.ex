defmodule Lovelace.Calendar.Payload do
  @moduledoc false
  @max_bytes 512 * 1024

  def calendars(%{calendars: list, truncated: truncated}) when is_list(list) do
    calendars =
      list
      |> Enum.take(100)
      |> Enum.map(fn calendar ->
        %{
          "id" => text(value(calendar, :id), 1024),
          "name" => text(value(calendar, :name), 1024),
          "selected" => value(calendar, :selected) == true
        }
      end)
      |> Enum.reject(&(&1["id"] == ""))
      |> Enum.uniq_by(& &1["id"])

    {calendars, byte_limited} = bound_calendars(calendars)
    {:ok, calendars, truncated == true or length(list) > 100 or byte_limited}
  end

  def calendars(_), do: {:error, :provider}

  defp bound_calendars(calendars) do
    {rows, _, limited} =
      Enum.reduce(calendars, {[], 2, false}, fn row, {rows, bytes, limited} ->
        size = byte_size(Jason.encode!(row)) + 1

        if bytes + size <= 192 * 1024,
          do: {[row | rows], bytes + size, limited},
          else: {rows, bytes, true}
      end)

    {Enum.reverse(rows), limited}
  end

  def selected(calendars, state) do
    ids =
      if state.explicit_selection,
        do: state.selected_ids,
        else: calendars |> Enum.filter(& &1["selected"]) |> Enum.map(& &1["id"])

    known = MapSet.new(calendars, & &1["id"])
    ids = Enum.filter(ids, &MapSet.member?(known, &1))
    {Enum.take(ids, 20), length(ids) > 20}
  end

  def events(%{events: events, truncated: truncated}, calendar, window) when is_list(events) do
    result =
      events
      |> Enum.take(100)
      |> Enum.filter(&overlap?(&1, window))
      |> Enum.map(fn event ->
        %{
          "id" => text(value(event, :id), 1024),
          "title" => text(value(event, :title), 4096),
          "start" => normalized_endpoint(event, :start),
          "end" => normalized_endpoint(event, :end),
          "all_day" => value(event, :all_day) == true,
          "url" => safe_url(value(event, :url)),
          "calendar_id" => calendar["id"],
          "calendar_name" => calendar["name"]
        }
      end)

    {:ok, result, truncated == true or length(events) > 100}
  end

  def events(_, _, _), do: {:error, :provider}

  def bounded(calendars, events) do
    base =
      byte_size(
        Jason.encode!(%{calendars: calendars, selected_ids: Enum.map(calendars, & &1["id"])})
      )

    {kept, _, truncated} =
      Enum.reduce(events, {[], base, false}, fn event, {kept, size, truncated} ->
        bytes = byte_size(Jason.encode!(event)) + 1

        if length(kept) < 500 and size + bytes <= @max_bytes - 2048,
          do: {[event | kept], size + bytes, truncated},
          else: {kept, size, true}
      end)

    {Enum.sort_by(kept, &{&1["start"], &1["calendar_id"], &1["id"]}), truncated}
  end

  def display(map, fields), do: Map.new(fields, &{&1, map[Atom.to_string(&1)]})
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text(value, limit) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn char, {chars, size} ->
      if size + byte_size(char) <= limit,
        do: {:cont, {[char | chars], size + byte_size(char)}},
        else: {:halt, {chars, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp text(_, _), do: ""
  defp endpoint(value) when is_binary(value), do: value
  defp endpoint(value) when is_map(value), do: value(value, :dateTime) || value(value, :date)
  defp endpoint(_), do: nil

  defp normalized_endpoint(event, key) do
    raw = endpoint(value(event, key))

    if value(event, :all_day) == true do
      raw
    else
      {:ok, time, _} = DateTime.from_iso8601(raw)
      DateTime.to_iso8601(time)
    end
  end

  defp overlap?(event, window) do
    start = endpoint(value(event, :start))
    finish = endpoint(value(event, :end))

    value(event, :status) != "cancelled" and
      interval_overlap?(value(event, :all_day) == true, start || "", finish || "", window)
  end

  defp interval_overlap?(true, start, finish, window) do
    with {:ok, first} <- Date.from_iso8601(start),
         {:ok, last} <- Date.from_iso8601(finish) do
      Date.compare(first, window.local_date) != :gt and
        Date.compare(last, window.local_date) == :gt
    else
      _ -> false
    end
  end

  defp interval_overlap?(false, start, finish, window) do
    with {:ok, first, _} <- DateTime.from_iso8601(start),
         {:ok, last, _} <- DateTime.from_iso8601(finish) do
      DateTime.compare(first, window.to_at) == :lt and
        DateTime.compare(last, window.from_at) == :gt and DateTime.compare(last, first) == :gt
    else
      _ -> false
    end
  end

  defp safe_url(url) when is_binary(url) and byte_size(url) <= 4096 do
    with true <- String.valid?(url) and not Regex.match?(~r/[\s\\\x00-\x1F\x7F]/u, url),
         %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           port: 443,
           authority: authority,
           path: path
         }
         when host in ["calendar.google.com", "www.google.com"] <- URI.parse(url),
         true <- authority in [host, host <> ":443"] and calendar_path?(path) do
      url
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
end

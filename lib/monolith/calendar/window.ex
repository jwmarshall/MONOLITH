defmodule Monolith.Calendar.Window do
  @moduledoc false

  def parse(from, to, date) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from),
         {:ok, to, 0} <- DateTime.from_iso8601(to),
         {:ok, date} <- Date.from_iso8601(date),
         seconds when seconds > 0 and seconds <= 26 * 3600 <- DateTime.diff(to, from),
         true <- abs(Date.diff(date, DateTime.to_date(from))) <= 1 do
      {:ok, %{from_at: from, to_at: to, local_date: date}}
    else
      _ -> {:error, :invalid_window}
    end
  end

  def fresh?(window) do
    now = DateTime.utc_now()
    DateTime.compare(window.from_at, now) != :gt and DateTime.compare(window.to_at, now) == :gt
  end

  def matches?(state, window) do
    state && state.local_date == window.local_date &&
      DateTime.compare(state.from_at, window.from_at) == :eq &&
      DateTime.compare(state.to_at, window.to_at) == :eq
  end

  def timezone?(label),
    do:
      is_binary(label) and byte_size(label) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9_+\-\/:. ]+\z/, label)
end

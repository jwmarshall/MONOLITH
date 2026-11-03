defmodule LovelaceWeb.HomeCalendar do
  @moduledoc "Browser-day context and local Calendar intent; provider work belongs to jobs."
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  @owner %{role: :local_owner}

  def init(socket),
    do: assign(socket, calendar_window: nil, calendar_accounts: [], calendar_revision: 0)

  def reload(socket) do
    case Lovelace.Mail.list_accounts(actor: @owner) do
      {:ok, accounts} ->
        accounts = Enum.reject(accounts, &(&1.status == :disconnected))
        socket = assign(socket, :calendar_accounts, accounts)
        prepare(socket)

      _ ->
        assign(socket, :calendar_accounts, [])
    end
  end

  def changed(socket),
    do: assign(socket, :calendar_revision, socket.assigns.calendar_revision + 1)

  def handle_event("calendar:day", params, socket) do
    case window(params) do
      {:ok, window} ->
        {:noreply, socket |> assign(:calendar_window, window) |> reload() |> changed()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar:refresh", %{"id" => id}, socket) do
    result = Lovelace.Calendar.refresh(id, actor: @owner)
    {:noreply, feedback(socket, result) |> changed()}
  end

  def handle_event("calendar:select", %{"account_id" => id} = params, socket) do
    ids = Map.get(params, "calendar_ids", [])
    ids = if is_list(ids), do: Enum.reject(ids, &(&1 == "")), else: ids
    result = Lovelace.Calendar.select_calendars(id, ids, actor: @owner)
    {:noreply, feedback(socket, result) |> changed()}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp feedback(socket, {:ok, _}), do: socket

  defp feedback(socket, _),
    do:
      put_flash(
        socket,
        :error,
        "Calendar could not be updated. Check the selection and connection."
      )

  defp prepare(%{assigns: %{calendar_window: nil}} = socket), do: socket

  defp prepare(socket) do
    window = socket.assigns.calendar_window

    Enum.each(socket.assigns.calendar_accounts, fn account ->
      if account.calendar_enabled && account.status == :ready do
        Lovelace.Calendar.prepare(
          account.id,
          window.from,
          window.to,
          window.date,
          window.timezone,
          actor: @owner
        )
      end
    end)

    socket
  end

  defp window(%{"from" => from, "to" => to, "date" => date, "timezone" => timezone})
       when is_binary(from) and is_binary(to) and is_binary(date) and is_binary(timezone) and
              byte_size(from) <= 40 and byte_size(to) <= 40 and byte_size(date) == 10 and
              byte_size(timezone) <= 100 do
    with {:ok, first, 0} <- DateTime.from_iso8601(from),
         {:ok, last, 0} <- DateTime.from_iso8601(to),
         {:ok, _} <- Date.from_iso8601(date),
         seconds when seconds >= 22 * 3600 and seconds <= 26 * 3600 <-
           DateTime.diff(last, first),
         true <- DateTime.diff(DateTime.utc_now(), first) in 0..(26 * 3600) do
      {:ok, %{from: from, to: to, date: date, timezone: timezone}}
    else
      _ -> :error
    end
  end

  defp window(_), do: :error
end

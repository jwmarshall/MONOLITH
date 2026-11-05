defmodule LovelaceWeb.HomeGoogle do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  def init(socket), do: assign(socket, :google_status, :unknown)

  def open(socket) do
    socket
    |> assign(:google_status, :loading)
    |> start_async(:google_status, fn ->
      Lovelace.Google.client_status(actor: %{role: :local_owner})
    end)
  end

  def handle_async({:ok, {:ok, status}}, socket)
      when status in [:stored, :not_connected, :locked, :unavailable, :invalid],
      do: {:noreply, assign(socket, :google_status, status)}

  def handle_async(_, socket), do: {:noreply, assign(socket, :google_status, :unavailable)}
end

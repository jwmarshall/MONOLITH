defmodule LovelaceWeb.HomeGemini do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  def init(socket), do: assign(socket, :gemini_status, :unknown)

  def open(socket) do
    socket
    |> assign(:gemini_status, :loading)
    |> start_async(:gemini_status, fn ->
      Lovelace.StageDesigner.gemini_connection_status(actor: %{role: :local_owner})
    end)
  end

  def handle_async({:ok, {:ok, status}}, socket)
      when status in [:stored, :not_connected, :locked, :unavailable, :invalid],
      do: {:noreply, assign(socket, :gemini_status, status)}

  def handle_async(_, socket), do: {:noreply, assign(socket, :gemini_status, :unavailable)}
end

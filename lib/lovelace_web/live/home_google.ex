defmodule LovelaceWeb.HomeGoogle do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias LovelaceWeb.HomeConnectionDiagnostic

  def init(socket) do
    socket |> assign(:google_status, :unknown) |> HomeConnectionDiagnostic.init(:google)
  end

  def open(socket), do: HomeConnectionDiagnostic.open(socket, :google)
  defdelegate handle_info(message, socket), to: HomeConnectionDiagnostic
end

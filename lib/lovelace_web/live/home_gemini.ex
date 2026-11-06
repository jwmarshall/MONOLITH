defmodule LovelaceWeb.HomeGemini do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias LovelaceWeb.HomeConnectionDiagnostic

  def init(socket) do
    socket |> assign(:gemini_status, :unknown) |> HomeConnectionDiagnostic.init(:gemini)
  end

  def open(socket), do: HomeConnectionDiagnostic.open(socket, :gemini)
  defdelegate handle_info(message, socket), to: HomeConnectionDiagnostic
end

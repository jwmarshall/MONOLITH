defmodule Lovelace.StageDesigner.GeminiTransport do
  @moduledoc "Compatibility adapter for the shared, bounded Gemini transport."

  alias Lovelace.Integrations.Gemini.Transport

  @doc false
  defdelegate run(request), to: Transport

  if Mix.env() == :test do
    @doc false
    defdelegate production_connection_options(timeout), to: Transport

    @doc false
    defdelegate run_on_loopback_tls(request, port), to: Transport

    @doc false
    defdelegate run_on_loopback(request, port), to: Transport
  end
end

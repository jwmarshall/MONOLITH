defmodule Monolith.StageDesigner.CredentialOperations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Monolith.ConnectionDiagnostics
  alias Monolith.Integrations.Gemini.Credentials

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :status ->
        {:ok, Credentials.status()}

      operation when operation in [:save, :delete] ->
        ConnectionDiagnostics.serial(:gemini, fn -> mutate(input, operation) end)
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp mutate(input, operation) do
    with :ok <- ConnectionDiagnostics.invalidate(:gemini) do
      persist(input, operation)
    end
  end

  defp persist(input, :save), do: Credentials.save(input.arguments.api_key)
  defp persist(_input, :delete), do: Credentials.delete()
end

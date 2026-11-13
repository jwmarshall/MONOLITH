defmodule Monolith.Google.Credentials do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.Mail.OAuth

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :status ->
        {:ok, ClientCredentials.status()}

      :save ->
        result = save(input.arguments.client_id, input.arguments.client_secret)

        case result do
          :ok ->
            {:ok, true}

          {:error, reason} when reason in [:invalid_configuration, :locked, :unavailable] ->
            {:error, reason}

          _ ->
            {:error, :unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp save(client_id, client_secret) do
    Monolith.ConnectionDiagnostics.serial(:google, fn ->
      persist_client(client_id, client_secret)
    end)
  end

  defp persist_client(client_id, client_secret) do
    with :ok <- Monolith.ConnectionDiagnostics.invalidate(:google) do
      OAuth.client_change(fn -> ClientCredentials.save(client_id, client_secret) end)
    end
  end
end

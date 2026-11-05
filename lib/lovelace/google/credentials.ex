defmodule Lovelace.Google.Credentials do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.Integrations.Google.ClientCredentials

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :status ->
        {:ok, ClientCredentials.status()}

      :save ->
        case ClientCredentials.save(input.arguments.client_id, input.arguments.client_secret) do
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
end

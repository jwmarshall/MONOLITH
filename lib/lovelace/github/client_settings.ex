defmodule Lovelace.GitHub.ClientSettings do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Lovelace.GitHub.{ClientCredentials, Error}

  @impl true
  def run(input, opts, _context) do
    result =
      case opts[:operation] do
        :status ->
          ClientCredentials.status()

        :save ->
          case ClientCredentials.save(
                 input.arguments.client_id,
                 input.arguments.client_secret,
                 input.arguments.app_slug
               ) do
            :ok -> {:ok, true}
            error -> error
          end
      end

    case result do
      {:error, reason} -> {:error, Error.exception(reason: reason)}
      other -> other
    end
  end
end

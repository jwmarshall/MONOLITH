defmodule Lovelace.OAuth.Operation do
  @moduledoc false
  use Ash.Resource, domain: Lovelace.OAuth, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :exchange, :map do
      argument :attempt_id, :uuid, allow_nil?: false
      argument :provider, :atom, allow_nil?: false, constraints: [one_of: [:google, :github]]
      run Lovelace.OAuth.Admission
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end
end

defmodule Lovelace.OAuth.Admission do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Lovelace.OAuth.{Exchange, Worker}
  alias Lovelace.Security.Vault

  @impl true
  def run(input, _, _) do
    id = input.arguments.attempt_id
    provider = input.arguments.provider

    Vault.with_access(fn -> reserve(id, provider) end)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp reserve(id, provider) do
    case Ash.transact(Exchange, fn -> enqueue(id, provider) end) do
      {:ok, reference} -> {:ok, reference}
      _ -> {:error, :unavailable}
    end
  end

  defp enqueue(id, provider) do
    with :ok <- Exchange.capacity(),
         {:ok, exchange} <- Exchange.reserve(id, provider),
         {:ok, job} <- Oban.insert(Worker.new(%{attempt_id: id})),
         {:ok, _} <- Exchange.record(exchange, %{job_id: job.id}) do
      %{id: id, job_id: job.id}
    else
      _ -> Lovelace.Repo.rollback(:unavailable)
    end
  end
end

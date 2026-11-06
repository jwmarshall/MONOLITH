defmodule Lovelace.TestSupport.GitHubDiscovery do
  @moduledoc false
  alias Lovelace.GitHub
  @owner %{role: :local_owner}

  def discover(id) do
    with {:ok, _operation} <- GitHub.discover(id, actor: @owner) do
      finish(id)
    end
  end

  def finish(id) do
    Oban.drain_queue(queue: :github, with_safety: false)
    account = GitHub.directory!(actor: @owner).connections |> Enum.find(&(&1.id == id))

    case account.discovery_status do
      :succeeded -> {:ok, account}
      :failed -> {:error, account.discovery_error}
      :superseded -> {:error, :reconnect}
      status -> raise "synthetic GitHub discovery did not settle: #{status}"
    end
  end
end

defmodule Lovelace.TestGitHub do
  @moduledoc false
  use Agent
  @behaviour Lovelace.Integrations.GitHub

  def start_link(options \\ []) do
    Agent.start_link(
      fn ->
        Map.merge(
          %{
            tokens: %{},
            calls: [],
            identities: %{},
            installation_sets: %{},
            response: :ok,
            user_response: :ok,
            installation_response: :ok,
            refresh_response: :ok,
            exchange_response: :ok,
            keychain_error: nil,
            keychain_put_error: nil,
            keychain_delete_error: nil,
            rows: [row()],
            repositories: nil,
            issues: [issue()],
            workflow_runs: [workflow_run()]
          },
          Map.new(options)
        )
      end,
      name: __MODULE__
    )
  end

  def configure(changes), do: Agent.update(__MODULE__, &Map.merge(&1, Map.new(changes)))
  def state, do: Agent.get(__MODULE__, & &1)

  def record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> calls ++ [call] end))

  @impl true
  def exchange_code(client_id, client_secret, code, verifier, redirect_uri) do
    record({:exchange_code, client_id, client_secret, code, verifier, redirect_uri})
    respond(state().exchange_response, {:ok, bundle()})
  end

  @impl true
  def refresh_token(client_id, client_secret, refresh) do
    record({:refresh_token, client_id, client_secret, refresh})
    respond(state().refresh_response, {:ok, bundle("github_access_rotated")})
  end

  @impl true
  def user(token) do
    record({:user, token})

    identity =
      Map.get(state().identities, token, %{github_id: "USER_SYNTHETIC", login: "synthetic"})

    respond(state().user_response, {:ok, identity})
  end

  @impl true
  def installations(token) do
    record({:installations, token})

    owners =
      Map.get(state().installation_sets, token, [
        owner(),
        owner(%{
          github_id: "USER_SYNTHETIC",
          login: "synthetic",
          owner_type: :user,
          installation_id: 2
        })
      ])

    respond(state().installation_response, {:ok, owners})
  end

  @impl true
  def pull_requests(token, owner) do
    record({:pull_requests, token, owner})

    respond(
      state().response,
      {:ok,
       %{
         pull_requests: state().rows,
         repositories:
           state().repositories || [repository(%{"full_name" => owner.login <> "/repo"})],
         issues: state().issues,
         workflow_runs: state().workflow_runs,
         issue_count: length(state().issues),
         issues_truncated: false,
         actions_truncated: false,
         total_count: length(state().rows),
         truncated: false,
         partial_reasons: []
       }}
    )
  end

  defp respond(:ok, default), do: default

  defp respond({:wait, parent, response}, _default) do
    send(parent, {:github_waiting, self()})

    receive do
      :continue -> response
    end
  end

  defp respond(response, _default), do: response

  def bundle(token \\ "github_access_fake") do
    %{
      access_token: token,
      refresh_token: "refresh_" <> token,
      expires_in: 28_800,
      refresh_token_expires_in: 15_552_000
    }
  end

  def owner(overrides \\ %{}) do
    Map.merge(
      %{installation_id: 1, github_id: "ORG_ACME", login: "acme", owner_type: :organization},
      overrides
    )
  end

  def row(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 7,
        "title" => "Synthetic pull request",
        "url" => "https://github.com/acme/repo/pull/7",
        "repository" => "acme/repo",
        "repository_id" => "REPO_SYNTHETIC",
        "author" => "synthetic",
        "is_draft" => false,
        "review_decision" => "REVIEW_REQUIRED",
        "checks" => "SUCCESS",
        "updated_at" => "2026-11-04T01:00:00Z",
        "created_at" => "2026-11-03T01:00:00Z"
      },
      overrides
    )
  end

  def repository(overrides \\ %{}) do
    Map.merge(
      %{"id" => "REPO_SYNTHETIC", "name" => "repo", "full_name" => "acme/repo"},
      overrides
    )
  end

  def issue(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 8,
        "title" => "Synthetic issue",
        "url" => "https://github.com/acme/repo/issues/8",
        "repository" => "acme/repo",
        "repository_id" => "REPO_SYNTHETIC",
        "author" => "synthetic",
        "updated_at" => "2026-11-04T01:00:00Z"
      },
      overrides
    )
  end

  def workflow_run(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 9,
        "name" => "Synthetic CI",
        "url" => "https://github.com/acme/repo/actions/runs/9",
        "status" => "completed",
        "conclusion" => "success",
        "repository" => "acme/repo",
        "repository_id" => "REPO_SYNTHETIC",
        "author" => "synthetic",
        "updated_at" => "2026-11-04T01:00:00Z"
      },
      overrides
    )
  end
end

defmodule Lovelace.TestGitHubKeychain do
  @moduledoc false
  alias Lovelace.TestGitHub
  @behaviour Lovelace.Integrations.GitHub.Keychain

  @impl true
  def get(id) do
    case TestGitHub.state().keychain_error do
      nil -> Map.fetch(TestGitHub.state().tokens, id) |> found()
      error -> {:error, error}
    end
  end

  @impl true
  def put(id, token) do
    case TestGitHub.state().keychain_put_error || TestGitHub.state().keychain_error do
      nil ->
        Agent.update(TestGitHub, &put_in(&1, [:tokens, id], token))
        :ok

      error ->
        {:error, error}
    end
  end

  @impl true
  def delete(id) do
    case TestGitHub.state().keychain_delete_error || TestGitHub.state().keychain_error do
      nil ->
        Agent.update(
          TestGitHub,
          &Map.update!(&1, :tokens, fn tokens -> Map.delete(tokens, id) end)
        )

        :ok

      error ->
        {:error, error}
    end
  end

  defp found({:ok, value}), do: {:ok, value}
  defp found(:error), do: {:error, :not_found}
end

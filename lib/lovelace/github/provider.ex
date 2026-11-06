defmodule Lovelace.GitHub.Provider do
  @moduledoc """
  Application-owned GitHub App authorization and installation snapshot contract.

  Secrets are ephemeral inputs/results, never diagnostic data. Exchange and rotating
  refresh are one-shot: `:provider` may mean an unknown remote outcome and does not
  authorize replay. The application reserves refresh durably before calling it.

  Installation discovery is complete or fails, bounded to 500 installations. A snapshot
  rechecks immutable installation/repository access before returning; it fails above
  100 repositories. Reads have a 60-second operation deadline, 20-second request limit
  and 2 MiB response limit. Snapshots retain the newest 50 PRs/issues and 50 Actions
  runs, not a mirror. Optional/limited reads set truncation flags and safe partial
  reasons; unknown counts remain nil rather than becoming zero. The application adds
  publication freshness and expires private cache contents after 24 hours.
  """

  @type error :: :configuration | :denied | :expired | :reconnect | :rate_limited | :provider
  @type result(value) :: {:ok, value} | {:error, error()}
  @type identity :: %{github_id: binary(), login: binary()}
  @type installation :: %{
          github_id: binary(),
          login: binary(),
          owner_type: :user | :organization,
          installation_id: pos_integer()
        }
  @type token_bundle :: %{
          access_token: binary(),
          refresh_token: binary(),
          expires_in: pos_integer(),
          refresh_token_expires_in: pos_integer()
        }
  @type snapshot :: %{
          repositories: [map()],
          pull_requests: [map()],
          issues: [map()],
          workflow_runs: [map()],
          total_count: non_neg_integer() | nil,
          issue_count: non_neg_integer() | nil,
          truncated: boolean(),
          issues_truncated: boolean(),
          actions_truncated: boolean(),
          partial_reasons: [binary()]
        }

  @callback exchange_code(binary(), binary(), binary(), binary(), binary()) ::
              result(token_bundle())
  @callback refresh_token(binary(), binary(), binary()) :: result(token_bundle())
  @callback user(binary()) :: result(identity())
  @callback installations(binary()) :: result([installation()])
  @callback installation_snapshot(binary(), installation()) :: result(snapshot())
end

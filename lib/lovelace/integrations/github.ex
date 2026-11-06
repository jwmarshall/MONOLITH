defmodule Lovelace.Integrations.GitHub do
  @moduledoc "Read-only GitHub App web authorization and installation-scoped snapshots."
  @behaviour Lovelace.GitHub.Provider
  alias Lovelace.Integrations.GitHub.Transport

  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/
  @repository ~r/\A[A-Za-z0-9_.-]{1,100}\z/
  @max_body 2 * 1024 * 1024
  @max_installations 500
  @max_repositories 100
  @batch_size 20
  @actions_repositories 10

  @impl true
  def exchange_code(client_id, client_secret, code, verifier, redirect_uri) do
    if valid_secret?(client_secret) and valid_secret?(code) and
         is_binary(verifier) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, verifier) and
         Transport.valid_callback_uri?(redirect_uri) do
      case oauth("/login/oauth/access_token", client_id, %{
             client_secret: client_secret,
             code: code,
             code_verifier: verifier,
             redirect_uri: redirect_uri
           }) do
        {:ok, body} -> bundle(body)
        other -> other
      end
    else
      {:error, :configuration}
    end
  end

  # The caller durably reserves the old pair before this one-shot rotation request.
  @impl true
  def refresh_token(client_id, client_secret, refresh) do
    if valid_secret?(client_secret) and valid_secret?(refresh) and
         byte_size(refresh) > 4 and String.starts_with?(refresh, "ghr_") do
      case oauth("/login/oauth/access_token", client_id, %{
             client_secret: client_secret,
             refresh_token: refresh,
             grant_type: "refresh_token"
           }) do
        {:ok, body} -> bundle(body)
        other -> other
      end
    else
      {:error, :reconnect}
    end
  end

  @impl true
  def user(token) do
    with {:ok, body} <- api("GET", "/user", token),
         %{"type" => "User", "id" => id, "node_id" => node_id, "login" => login} <- body,
         true <- positive_id?(id) and valid_id?(node_id) and valid_login?(login) do
      {:ok, %{github_id: node_id, login: login}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  @impl true
  def installations(token), do: installation_pages(token, 1, nil, [], now() + 60_000)

  defp installation_pages(token, page, expected, acc, deadline) do
    with {:ok, body} <-
           api("GET", "/user/installations?per_page=100&page=#{page}", token, "", deadline),
         %{"total_count" => count, "installations" => items} <- body,
         true <- is_integer(count) and count in 0..@max_installations,
         true <- expected == nil or expected == count,
         true <- is_list(items) and length(items) <= 100,
         true <- length(acc) + length(items) <= count do
      all = acc ++ items

      cond do
        length(all) == count ->
          parse_installations(all)

        length(items) == 100 and page < div(@max_installations, 100) ->
          installation_pages(token, page + 1, count, all, deadline)

        true ->
          {:error, :provider}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  defp parse_installations(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case installation(item) do
        {:ok, owner} -> {:cont, {:ok, [owner | acc]}}
        :suspended -> {:cont, {:ok, acc}}
        _ -> {:halt, {:error, :provider}}
      end
    end)
    |> case do
      {:ok, owners} ->
        ids = Enum.map(owners, & &1.installation_id)

        if length(Enum.uniq(ids)) == length(ids),
          do: {:ok, Enum.reverse(owners)},
          else: {:error, :provider}

      error ->
        error
    end
  end

  defp installation(%{"id" => id, "account" => account} = item) do
    with true <- positive_id?(id),
         {:ok, owner} <- identity(account) do
      if item["suspended_at"] == nil,
        do: {:ok, Map.put(owner, :installation_id, id)},
        else: :suspended
    else
      _ -> {:error, :provider}
    end
  end

  defp installation(_), do: {:error, :provider}

  defp identity(%{"node_id" => id, "login" => login, "type" => type})
       when type in ["User", "Organization"] do
    if valid_id?(id) and valid_login?(login) do
      {:ok,
       %{
         github_id: id,
         login: login,
         owner_type: if(type == "User", do: :user, else: :organization)
       }}
    else
      {:error, :provider}
    end
  end

  defp identity(_), do: {:error, :provider}

  @impl true
  def installation_snapshot(token, owner) do
    deadline = now() + 60_000

    with true <- valid_owner?(owner),
         {:ok, accessible} <- installation_pages(token, 1, nil, [], deadline),
         true <- Enum.any?(accessible, &same_owner?(&1, owner)),
         {:ok, repositories} <- repositories(token, owner, deadline),
         {:ok, snapshot} <- repository_batches(token, owner, repositories, deadline),
         actions = workflow_runs(token, owner, repositories, deadline - 10_000),
         :ok <- verify_scope(token, owner, repositories, deadline) do
      repository_list =
        repositories
        |> Enum.map(
          &%{"id" => &1.id, "name" => &1.name, "full_name" => owner.login <> "/" <> &1.name}
        )
        |> Enum.sort_by(& &1["full_name"])

      {:ok,
       snapshot
       |> Map.merge(actions)
       |> Map.put(:repositories, repository_list)
       |> Map.put(
         :partial_reasons,
         Enum.uniq(snapshot.partial_reasons ++ actions.partial_reasons)
       )}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :reconnect}
      _ -> {:error, :provider}
    end
  rescue
    _ -> {:error, :provider}
  end

  # Recheck after the reads too: a public repository may remain readable after
  # removal from an installation, so GraphQL success alone is not access proof.
  defp verify_scope(token, owner, previous, deadline) do
    with {:ok, accessible} <- installation_pages(token, 1, nil, [], deadline),
         true <- Enum.any?(accessible, &same_owner?(&1, owner)),
         {:ok, current} <- repositories(token, owner, deadline),
         true <- Enum.sort(current) == Enum.sort(previous) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :reconnect}
    end
  end

  defp valid_owner?(%{installation_id: id, github_id: node_id, login: login, owner_type: type}),
    do:
      positive_id?(id) and valid_id?(node_id) and valid_login?(login) and
        type in [:user, :organization]

  defp valid_owner?(_), do: false

  defp same_owner?(left, right),
    do:
      left.installation_id == right.installation_id and left.github_id == right.github_id and
        left.owner_type == right.owner_type and same_login?(left.login, right.login)

  # Fail rather than publish a misleading complete snapshot beyond this bound.
  # Never use org/user-wide search: public repositories outside the installation
  # remain excluded even when the user token can read them.
  defp repositories(token, owner, deadline) do
    with {:ok, body} <-
           api(
             "GET",
             "/user/installations/#{owner.installation_id}/repositories?per_page=100&page=1",
             token,
             "",
             deadline
           ),
         %{"total_count" => count, "repositories" => repos} <- body,
         true <- is_integer(count) and count in 0..@max_repositories,
         true <- is_list(repos) and length(repos) == count do
      Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, acc} ->
        accumulate_repository(repo, owner, acc)
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  defp accumulate_repository(repo, owner, acc) do
    with %{"id" => id, "node_id" => node_id, "name" => name, "owner" => account} <- repo,
         true <- positive_id?(id) and valid_id?(node_id) and valid_repository?(name),
         {:ok, identity} <- identity(account),
         true <-
           identity.github_id == owner.github_id and identity.owner_type == owner.owner_type and
             same_login?(identity.login, owner.login),
         false <- Enum.any?(acc, &(&1.id == node_id or &1.name == name)) do
      {:cont, {:ok, [%{id: node_id, name: name} | acc]}}
    else
      _ -> {:halt, {:error, :provider}}
    end
  end

  defp repository_batches(token, owner, repositories, deadline) do
    repositories
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(
      {:ok, empty_batch()},
      fn repos, {:ok, acc} ->
        {query, variables} = query(repos)

        with {:ok, body} <-
               api(
                 "POST",
                 "/graphql",
                 token,
                 Jason.encode!(%{query: query, variables: variables}),
                 deadline
               ),
             {:ok, reasons} <- partial_errors(body, length(repos)),
             %{"data" => %{} = data} <- body,
             {:ok, batch} <- batch_rows(data, repos, owner) do
          rows = newest(acc.pull_requests ++ batch.pull_requests)

          {:cont,
           {:ok,
            %{
              pull_requests: rows,
              issues: newest(acc.issues ++ batch.issues),
              total_count: acc.total_count + batch.total_count,
              issue_count: add_counts(acc.issue_count, batch.issue_count),
              issues_truncated: acc.issues_truncated or batch.issues_truncated,
              partial_reasons: reasons ++ batch.partial_reasons ++ acc.partial_reasons
            }}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :provider}}
        end
      end
    )
    |> case do
      {:ok, data} ->
        reasons =
          if data.total_count > 50,
            do: ["first_50" | data.partial_reasons],
            else: data.partial_reasons

        issues_more = issues_partial?(data, reasons)

        reasons =
          if data.issue_count && data.issue_count > 50,
            do: ["issues_first_50" | reasons],
            else: reasons

        reasons = Enum.uniq(reasons)

        {:ok,
         %{data | partial_reasons: reasons, issues_truncated: issues_more}
         |> Map.put(:truncated, Enum.any?(reasons, &(not String.starts_with?(&1, "issues_"))))}

      error ->
        error
    end
  end

  defp issues_partial?(data, reasons) do
    data.issues_truncated or is_nil(data.issue_count) or data.issue_count > 50 or
      "issues_unavailable" in reasons
  end

  defp empty_batch do
    %{
      pull_requests: [],
      issues: [],
      total_count: 0,
      issue_count: 0,
      issues_truncated: false,
      partial_reasons: []
    }
  end

  defp add_counts(nil, _), do: nil
  defp add_counts(_, nil), do: nil
  defp add_counts(left, right), do: left + right

  defp newest(rows),
    do:
      rows
      |> Enum.sort_by(
        &{DateTime.to_unix(elem(DateTime.from_iso8601(&1["updated_at"]), 1), :microsecond),
         &1["repository"], &1["number"]},
        :desc
      )
      |> Enum.take(50)

  defp query(repos) do
    checks =
      if Keyword.get(Application.get_env(:lovelace, :github, []), :checks, true),
        do: "commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }",
        else: ""

    fields =
      "number title isDraft reviewDecision updatedAt createdAt author { login } repository { id name owner { id login __typename } } #{checks}"

    indexed = Enum.with_index(repos)
    declarations = Enum.map_join(indexed, ", ", fn {_, i} -> "$id#{i}: ID!" end)

    selections =
      Enum.map_join(indexed, "\n", fn {_, i} ->
        "r#{i}: node(id: $id#{i}) { ... on Repository { id name owner { id login __typename } pullRequests(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount pageInfo { hasNextPage } nodes { #{fields} } } issues(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount pageInfo { hasNextPage } nodes { number title updatedAt author { login } repository { id name owner { id login __typename } } } } } }"
      end)

    {"query(#{declarations}) { #{selections} }",
     Map.new(indexed, fn {repo, i} -> {"id#{i}", repo.id} end)}
  end

  defp batch_rows(data, repos, owner) do
    repos
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, empty_batch()},
      fn {repo, i}, {:ok, acc} ->
        accumulate_batch_repository(data["r#{i}"], repo, owner, acc)
      end
    )
  end

  defp accumulate_batch_repository(result, repo, owner, acc) do
    with %{
           "id" => id,
           "name" => name,
           "owner" => account,
           "pullRequests" => %{
             "totalCount" => count,
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => more}
           }
         } <- result,
         true <- id == repo.id and name == repo.name and graphql_owner?(account, owner),
         true <- valid_batch_nodes?(count, nodes),
         true <- is_boolean(more),
         {:ok, rows} <- rows(nodes, owner, repo),
         {:ok, issues} <- issue_rows(result["issues"], owner, repo) do
      {:cont,
       {:ok,
        %{
          pull_requests: newest(rows ++ acc.pull_requests),
          issues: newest(issues.rows ++ acc.issues),
          total_count: acc.total_count + count,
          issue_count: add_counts(acc.issue_count, issues.count),
          issues_truncated: acc.issues_truncated or issues.truncated,
          partial_reasons:
            issues.reasons ++ incomplete_reasons(more, count, rows) ++ acc.partial_reasons
        }}}
    else
      _ -> {:halt, {:error, :provider}}
    end
  end

  defp valid_batch_nodes?(count, nodes),
    do:
      is_integer(count) and count >= 0 and is_list(nodes) and length(nodes) <= 50 and
        count >= length(nodes)

  defp incomplete_reasons(more, count, rows) do
    if (more and count <= 50) or length(rows) < min(count, 50),
      do: ["core_incomplete"],
      else: []
  end

  defp partial_errors(%{"errors" => errors}, size) when is_list(errors) and errors != [] do
    aliases = Enum.map(0..(size - 1), &"r#{&1}")

    cond do
      Enum.any?(errors, &(is_map(&1) and &1["type"] == "RATE_LIMITED")) ->
        {:error, :rate_limited}

      Enum.all?(errors, fn
        %{"path" => [key, "issues" | _]} ->
          key in aliases

        %{"path" => [key, "pullRequests", "nodes", index, field | _]}
        when is_integer(index) and index in 0..49 ->
          key in aliases and field in ["commits", "reviewDecision"]

        _ ->
          false
      end) ->
        {:ok,
         Enum.map(errors, fn %{"path" => [_, field | _]} ->
           if field == "issues", do: "issues_unavailable", else: "optional_fields_unavailable"
         end)}

      true ->
        {:error, :provider}
    end
  end

  defp partial_errors(%{"errors" => []}, _), do: {:ok, []}
  defp partial_errors(%{"errors" => _}, _), do: {:error, :provider}
  defp partial_errors(_, _), do: {:ok, []}

  defp graphql_owner?(%{"id" => id, "login" => login, "__typename" => type}, owner),
    do:
      id == owner.github_id and same_login?(login, owner.login) and
        type == if(owner.owner_type == :user, do: "User", else: "Organization")

  defp graphql_owner?(_, _), do: false

  defp rows(nodes, owner, repository) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      accumulate_row(node, owner, repository, acc)
    end)
  end

  defp accumulate_row(nil, _owner, _repository, acc), do: {:cont, {:ok, acc}}

  defp accumulate_row(node, owner, repository, acc) do
    with {:ok, row} <- row(node, owner, repository),
         false <- Enum.any?(acc, &(&1["number"] == row["number"])) do
      {:cont, {:ok, [row | acc]}}
    else
      _ -> {:halt, {:error, :provider}}
    end
  end

  defp row(
         %{
           "number" => number,
           "title" => title,
           "isDraft" => draft,
           "updatedAt" => updated,
           "createdAt" => created,
           "repository" => %{"id" => repository_id, "name" => name, "owner" => account}
         } = node,
         owner,
         repository
       ) do
    with true <-
           repository_id == repository.id and name == repository.name and
             graphql_owner?(account, owner),
         true <- is_integer(number) and number in 1..2_147_483_647,
         true <- valid_repository?(name),
         true <- is_binary(title) and byte_size(title) <= 4096 and is_boolean(draft),
         {:ok, _, _} <- DateTime.from_iso8601(updated),
         {:ok, _, _} <- DateTime.from_iso8601(created) do
      review = node["reviewDecision"]
      author = get_in(node, ["author", "login"])

      {:ok,
       %{
         "number" => number,
         "title" => title,
         "url" => "https://github.com/#{owner.login}/#{name}/pull/#{number}",
         "repository" => owner.login <> "/" <> name,
         "repository_id" => repository.id,
         "author" => if(valid_login?(author), do: author),
         "is_draft" => draft,
         "review_decision" =>
           if(review in ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"], do: review),
         "checks" => checks(node),
         "updated_at" => updated,
         "created_at" => created
       }}
    else
      _ -> {:error, :provider}
    end
  end

  defp row(_, _, _), do: {:error, :provider}

  defp issue_rows(nil, _owner, _repo),
    do: {:ok, %{rows: [], count: nil, truncated: true, reasons: ["issues_unavailable"]}}

  defp issue_rows(
         %{"totalCount" => count, "nodes" => nodes, "pageInfo" => %{"hasNextPage" => more}},
         owner,
         repo
       ) do
    with true <- valid_batch_nodes?(count, nodes) and is_boolean(more),
         {:ok, rows} <- parse_issue_nodes(nodes, owner, repo) do
      incomplete = more or count > length(rows)

      {:ok,
       %{
         rows: rows,
         count: count,
         truncated: incomplete,
         reasons: if(incomplete, do: ["issues_incomplete"], else: [])
       }}
    else
      _ -> {:error, :provider}
    end
  end

  defp issue_rows(_, _, _), do: {:error, :provider}

  defp parse_issue_nodes(nodes, owner, repo) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      with %{
             "number" => number,
             "title" => title,
             "updatedAt" => updated,
             "repository" => %{"id" => id, "name" => name, "owner" => account}
           } <- node,
           true <- id == repo.id and name == repo.name and graphql_owner?(account, owner),
           true <- is_integer(number) and number in 1..2_147_483_647,
           true <- is_binary(title) and byte_size(title) <= 4096,
           {:ok, _, _} <- DateTime.from_iso8601(updated),
           false <- Enum.any?(acc, &(&1["number"] == number)) do
        author = get_in(node, ["author", "login"])

        row = %{
          "number" => number,
          "title" => title,
          "url" => "https://github.com/#{owner.login}/#{repo.name}/issues/#{number}",
          "repository" => owner.login <> "/" <> repo.name,
          "repository_id" => repo.id,
          "author" => if(valid_login?(author), do: author),
          "updated_at" => updated
        }

        {:cont, {:ok, [row | acc]}}
      else
        _ -> {:halt, {:error, :provider}}
      end
    end)
  end

  # Actions are optional and explicitly partial: at most ten repositories and
  # ten recent runs per repository, without logs, artifacts or job detail calls.
  defp workflow_runs(token, owner, repositories, deadline) do
    reasons =
      if length(repositories) > @actions_repositories, do: ["actions_repository_limit"], else: []

    initial = %{workflow_runs: [], actions_truncated: reasons != [], partial_reasons: reasons}

    repositories
    |> Enum.sort_by(& &1.id)
    |> Enum.take(@actions_repositories)
    |> Enum.reduce_while(initial, fn repo, acc ->
      if now() >= deadline do
        {:halt, actions_partial(acc, "actions_deadline")}
      else
        accumulate_repository_runs(token, owner, repo, deadline, acc)
      end
    end)
  end

  defp accumulate_repository_runs(token, owner, repo, deadline, acc) do
    case repository_runs(token, owner, repo, deadline) do
      {:ok, rows, more} ->
        all = acc.workflow_runs ++ rows
        rows = all |> Enum.sort_by(&{&1["updated_at"], &1["id"]}, :desc) |> Enum.take(50)
        acc = %{acc | workflow_runs: rows}
        acc = if more, do: actions_partial(acc, "actions_recent_only"), else: acc
        {:cont, if(length(all) > 50, do: actions_partial(acc, "actions_first_50"), else: acc)}

      {:error, :rate_limited} ->
        {:halt, actions_partial(acc, "actions_rate_limited")}

      {:error, _} ->
        {:cont, actions_partial(acc, "actions_unavailable")}
    end
  end

  defp actions_partial(acc, reason),
    do: %{
      acc
      | actions_truncated: true,
        partial_reasons: Enum.uniq([reason | acc.partial_reasons])
    }

  defp repository_runs(token, owner, repo, deadline) do
    with {:ok, %{"total_count" => count, "workflow_runs" => runs}} <-
           api(
             "GET",
             "/repos/#{owner.login}/#{repo.name}/actions/runs?per_page=10&page=1",
             token,
             "",
             deadline
           ),
         true <- is_integer(count) and count >= 0 and is_list(runs) and length(runs) <= 10,
         true <- length(runs) == min(count, 10),
         {:ok, rows} <- parse_runs(runs, owner, repo) do
      {:ok, rows, count > length(rows)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  defp parse_runs(runs, owner, repo) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      with %{
             "id" => id,
             "name" => name,
             "status" => status,
             "conclusion" => conclusion,
             "updated_at" => updated,
             "repository" => %{
               "node_id" => repository_id,
               "name" => repository_name,
               "owner" => account
             }
           } <- run,
           true <- positive_id?(id) and is_binary(name) and byte_size(name) <= 4096,
           true <-
             status in ["queued", "in_progress", "completed", "waiting", "requested", "pending"],
           true <-
             conclusion in [
               nil,
               "success",
               "failure",
               "neutral",
               "cancelled",
               "skipped",
               "timed_out",
               "action_required",
               "stale",
               "startup_failure"
             ],
           true <- status == "completed" == not is_nil(conclusion),
           true <- repository_id == repo.id and repository_name == repo.name,
           {:ok, identity} <- identity(account),
           true <-
             identity.github_id == owner.github_id and identity.owner_type == owner.owner_type and
               same_login?(identity.login, owner.login),
           {:ok, _, _} <- DateTime.from_iso8601(updated),
           false <- Enum.any?(acc, &(&1["id"] == id)) do
        actor = get_in(run, ["actor", "login"])

        row = %{
          "id" => id,
          "name" => name,
          "status" => status,
          "conclusion" => conclusion,
          "repository" => owner.login <> "/" <> repo.name,
          "repository_id" => repo.id,
          "url" => "https://github.com/#{owner.login}/#{repo.name}/actions/runs/#{id}",
          "author" => if(valid_login?(actor), do: actor),
          "updated_at" => updated
        }

        {:cont, {:ok, [row | acc]}}
      else
        _ -> {:halt, {:error, :provider}}
      end
    end)
  end

  defp checks(node) do
    case get_in(node, ["commits", "nodes"]) do
      [%{"commit" => %{"statusCheckRollup" => %{"state" => state}}}]
      when state in ["SUCCESS", "FAILURE", "ERROR", "PENDING"] ->
        state

      _ ->
        nil
    end
  end

  defp oauth(path, client_id, params) do
    if is_binary(client_id) and Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, client_id) do
      with {:ok, body} <-
             request(
               "github.com",
               "POST",
               path,
               [
                 {"accept", "application/json"},
                 {"content-type", "application/x-www-form-urlencoded"},
                 {"accept-encoding", "identity"},
                 {"user-agent", "LOVELACE"}
               ],
               URI.encode_query(Map.put(params, :client_id, client_id))
             ) do
        oauth_result(body)
      end
    else
      {:error, :configuration}
    end
  end

  defp oauth_result(%{"error" => error}) do
    reason =
      case error do
        "access_denied" ->
          :denied

        value
        when value in [
               "expired_token",
               "token_expired",
               "bad_verification_code"
             ] ->
          :expired

        value
        when value in [
               "incorrect_client_credentials",
               "redirect_uri_mismatch",
               "unsupported_grant_type"
             ] ->
          :configuration

        "bad_refresh_token" ->
          :reconnect

        _ ->
          :provider
      end

    {:error, reason}
  end

  defp oauth_result(body), do: {:ok, body}

  defp bundle(%{
         "access_token" => access,
         "refresh_token" => refresh,
         "expires_in" => expires,
         "refresh_token_expires_in" => refresh_expires,
         "token_type" => "bearer",
         "scope" => ""
       }) do
    if valid_secret?(access) and byte_size(access) > 4 and String.starts_with?(access, "ghu_") and
         valid_secret?(refresh) and byte_size(refresh) > 4 and
         String.starts_with?(refresh, "ghr_") and
         positive_seconds?(expires, 86_400) and positive_seconds?(refresh_expires, 366 * 86_400) do
      {:ok,
       %{
         access_token: access,
         refresh_token: refresh,
         expires_in: expires,
         refresh_token_expires_in: refresh_expires
       }}
    else
      {:error, :provider}
    end
  end

  defp bundle(_), do: {:error, :provider}

  defp api(method, path, token, body \\ "", deadline \\ nil) do
    timeout = if deadline, do: min(20_000, deadline - now()), else: 20_000

    if valid_secret?(token) and timeout > 0 do
      request(
        "api.github.com",
        method,
        path,
        [
          {"accept", "application/vnd.github+json"},
          {"accept-encoding", "identity"},
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"},
          {"user-agent", "LOVELACE"},
          {"x-github-api-version", "2022-11-28"}
        ],
        body,
        timeout
      )
    else
      {:error, :provider}
    end
  end

  defp request(host, method, path, headers, body, timeout \\ 20_000) do
    with {:ok, response} <-
           transport().request(
             %{
               host: host,
               method: method,
               path: path,
               headers: headers,
               body: body,
               timeout_ms: timeout
             },
             []
           ),
         true <- is_binary(response.body) and byte_size(response.body) <= @max_body do
      decode(response)
    else
      _ -> {:error, :provider}
    end
  rescue
    _ -> {:error, :provider}
  catch
    _, _ -> {:error, :provider}
  end

  defp decode(%{status: 200, body: body}) do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :provider}
    end
  end

  defp decode(%{status: status, headers: headers}) when status in [403, 429] do
    if status == 429 or
         Enum.any?(headers, fn {name, value} ->
           String.downcase(name) == "retry-after" or
             (String.downcase(name) == "x-ratelimit-remaining" and value == "0")
         end), do: {:error, :rate_limited}, else: {:error, :reconnect}
  end

  defp decode(%{status: status}) when status in [401, 404], do: {:error, :reconnect}
  defp decode(_), do: {:error, :provider}

  defp transport,
    do:
      Keyword.get(
        Application.get_env(:lovelace, :github, []),
        :transport,
        Lovelace.Integrations.GitHub.Transport
      )

  defp now, do: System.monotonic_time(:millisecond)

  defp valid_secret?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1024 and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp valid_login?(value), do: is_binary(value) and Regex.match?(@login, value)

  defp same_login?(left, right),
    do:
      valid_login?(left) and valid_login?(right) and
        String.downcase(left) == String.downcase(right)

  defp valid_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9_=\/+-]+\z/, value)

  defp positive_id?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807

  defp positive_seconds?(value, max), do: is_integer(value) and value > 0 and value <= max

  defp valid_repository?(value),
    do: is_binary(value) and Regex.match?(@repository, value) and value not in [".", ".."]
end

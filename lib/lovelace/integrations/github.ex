defmodule Lovelace.Integrations.GitHub do
  @moduledoc "Read-only GitHub App device authorization and installation-scoped PR snapshots."

  @callback device_code(binary()) :: {:ok, map()} | {:error, atom()}
  @callback exchange_device(binary(), binary()) ::
              {:ok, map()} | {:error, atom()} | {:slow_down, pos_integer()}
  @callback refresh_token(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  @callback user(binary()) :: {:ok, map()} | {:error, atom()}
  @callback installations(binary()) :: {:ok, [map()]} | {:error, atom()}
  @callback pull_requests(binary(), map()) :: {:ok, map()} | {:error, atom()}

  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/
  @repository ~r/\A[A-Za-z0-9_.-]{1,100}\z/
  @max_body 2 * 1024 * 1024
  @max_installations 500
  @max_repositories 100
  @batch_size 20

  def device_code(client_id) do
    with {:ok, body} <- oauth("/login/device/code", client_id, %{scope: "offline_access"}),
         %{
           "device_code" => device,
           "user_code" => code,
           "expires_in" => expires,
           "interval" => interval
         } <- body,
         true <- valid_secret?(device),
         true <- is_binary(code) and Regex.match?(~r/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/, code),
         true <- positive_seconds?(expires, 900) and positive_seconds?(interval, 900) do
      {:ok, %{device_code: device, user_code: code, expires_in: expires, interval: interval}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  def exchange_device(client_id, device) do
    if valid_secret?(device) do
      case oauth("/login/oauth/access_token", client_id, %{
             device_code: device,
             grant_type: "urn:ietf:params:oauth:grant-type:device_code"
           }) do
        {:ok, body} -> bundle(body)
        other -> other
      end
    else
      {:error, :provider}
    end
  end

  # Device-issued refresh tokens deliberately need no client secret. The caller
  # must fence the old pair durably before this one-shot rotation request.
  def refresh_token(client_id, refresh) do
    if valid_secret?(refresh) and byte_size(refresh) > 4 and String.starts_with?(refresh, "ghr_") do
      case oauth("/login/oauth/access_token", client_id, %{
             refresh_token: refresh,
             grant_type: "refresh_token"
           }) do
        {:ok, body} -> bundle(body)
        {:slow_down, _} -> {:error, :rate_limited}
        {:error, :authorization_pending} -> {:error, :provider}
        other -> other
      end
    else
      {:error, :reconnect}
    end
  end

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

  def pull_requests(token, owner) do
    deadline = now() + 60_000

    with true <- valid_owner?(owner),
         {:ok, accessible} <- installation_pages(token, 1, nil, [], deadline),
         true <- Enum.any?(accessible, &same_owner?(&1, owner)),
         {:ok, repositories} <- repositories(token, owner, deadline),
         {:ok, snapshot} <- repository_batches(token, owner, repositories, deadline),
         :ok <- verify_scope(token, owner, repositories, deadline) do
      {:ok, snapshot}
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
      {:ok, %{pull_requests: [], total_count: 0, partial_reasons: []}},
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
              total_count: acc.total_count + batch.total_count,
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

        reasons = Enum.uniq(reasons)
        {:ok, %{data | partial_reasons: reasons} |> Map.put(:truncated, reasons != [])}

      error ->
        error
    end
  end

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
      "number title isDraft reviewDecision updatedAt createdAt author { login } repository { name owner { id login __typename } } #{checks}"

    indexed = Enum.with_index(repos)
    declarations = Enum.map_join(indexed, ", ", fn {_, i} -> "$id#{i}: ID!" end)

    selections =
      Enum.map_join(indexed, "\n", fn {_, i} ->
        "r#{i}: node(id: $id#{i}) { ... on Repository { id name owner { id login __typename } pullRequests(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount pageInfo { hasNextPage } nodes { #{fields} } } } }"
      end)

    {"query(#{declarations}) { #{selections} }",
     Map.new(indexed, fn {repo, i} -> {"id#{i}", repo.id} end)}
  end

  defp batch_rows(data, repos, owner) do
    repos
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, %{pull_requests: [], total_count: 0, partial_reasons: []}},
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
         {:ok, rows} <- rows(nodes, owner, repo.name) do
      {:cont,
       {:ok,
        %{
          pull_requests: newest(rows ++ acc.pull_requests),
          total_count: acc.total_count + count,
          partial_reasons: incomplete_reasons(more, count, rows) ++ acc.partial_reasons
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
        %{"path" => [key, "pullRequests", "nodes", index, field | _]}
        when is_integer(index) and index in 0..49 ->
          key in aliases and field in ["commits", "reviewDecision"]

        _ ->
          false
      end) ->
        {:ok, ["optional_fields_unavailable"]}

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
           "repository" => %{"name" => name, "owner" => account}
         } = node,
         owner,
         repository
       ) do
    with true <- name == repository and graphql_owner?(account, owner),
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

  defp oauth_result(%{"error" => "authorization_pending"}), do: {:error, :authorization_pending}

  defp oauth_result(%{"error" => "slow_down", "interval" => interval})
       when is_integer(interval) and interval > 0,
       do: {:slow_down, interval}

  defp oauth_result(%{"error" => error}) do
    reason =
      case error do
        "access_denied" ->
          :denied

        value
        when value in [
               "expired_token",
               "token_expired",
               "incorrect_device_code",
               "bad_verification_code"
             ] ->
          :expired

        value
        when value in [
               "incorrect_client_credentials",
               "device_flow_disabled",
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

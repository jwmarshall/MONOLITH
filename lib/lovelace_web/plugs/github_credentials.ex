defmodule LovelaceWeb.Plugs.GitHubCredentials do
  @moduledoc "Consumes owner-verified GitHub connection intent before instrumentation; credentials stay server-side."
  import Plug.Conn

  alias Lovelace.GitHub
  alias Lovelace.GitHub.{Auth, Error}
  alias Lovelace.Security.Vault
  alias LovelaceWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  @owner %{role: :local_owner}
  @failure_categories %{
    invalid_client_id: "invalid_client_id",
    invalid_client_secret: "invalid_client_secret",
    invalid_app_slug: "invalid_app_slug",
    locked: "locked",
    keychain: "keychain_failed",
    reconnect: "access_failed",
    rate_limited: "rate_limited",
    provider: "provider_failed",
    unavailable: "unavailable",
    configuration: "configuration"
  }

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.method not in ["GET", "HEAD"] &&
         SensitivePath.matches?(conn, ["connections", "github"]),
       do: consume(conn),
       else: conn
  end

  defp consume(conn) do
    conn = fetch_session(conn)

    with true <- conn.method == "POST" && conn.query_string == "",
         true <- form_content_type?(conn),
         {:ok, body, conn} <-
           read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5_000) do
      params = Query.decode(body)
      conn = scrub(conn, Map.take(params, ["_csrf_token"]))
      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))

      perform_verified(conn, params)
    else
      _ -> reject(conn, 400)
    end
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError -> reject(conn, 403)
    Plug.Conn.InvalidQueryError -> reject(conn, 400)
    _ -> reject(conn, 400)
  catch
    _, _ -> reject(conn, 400)
  end

  defp perform_verified(conn, params) do
    session = get_session(conn, :owner_session_token)

    case Lovelace.Owner.verify_session(session) do
      {:ok, _session} -> redirect_operation(conn, params, perform(params, session))
      _ -> redirect(conn, "/unlock")
    end
  end

  defp redirect_operation(conn, _params, {:authorization_url, url}),
    do: conn |> delete_session(:github_authorization_result) |> redirect(url)

  defp redirect_operation(conn, params, notice), do: redirect(conn, destination(params, notice))

  defp perform(%{"operation" => "sign_in"}, session) do
    case Auth.begin(session) do
      {:ok, url} -> {:authorization_url, url}
      error -> result(error, "failed")
    end
  end

  defp perform(
         %{
           "operation" => "save_client",
           "client_id" => id,
           "client_secret" => secret,
           "app_slug" => slug
         },
         session
       )
       when is_binary(id) and is_binary(secret) and is_binary(slug) do
    case Vault.with_access(fn -> save_client(session, id, secret, slug) end) do
      :saved -> "settings_saved"
      error -> result(error, "failed")
    end
  end

  defp perform(%{"operation" => "save_client"}, _), do: "invalid_settings"

  defp perform(%{"operation" => "cancel_sign_in"}, session) do
    case Auth.cancel(session) do
      :ok -> "cancelled"
      {:error, :already_authorized} -> "authorized"
      error -> result(error, "cancelled")
    end
  end

  defp perform(%{"operation" => "discover", "connection_id" => id}, _) when is_binary(id),
    do: result(GitHub.discover(id, actor: @owner), "discovery_queued")

  defp perform(%{"operation" => "disconnect_account", "connection_id" => id}, _)
       when is_binary(id),
       do: result(GitHub.disconnect_account(id, actor: @owner), "signed_out")

  defp perform(
         %{"operation" => "attach", "workspace_id" => workspace, "organization_id" => id},
         _
       )
       when is_binary(workspace) and is_binary(id),
       do: result(GitHub.attach(workspace, id, actor: @owner), "attached")

  defp perform(
         %{
           "operation" => "attach_repositories",
           "workspace_id" => workspace,
           "organization_id" => id,
           "repository_ids" => [_ | _] = ids
         },
         _
       )
       when is_binary(workspace) and is_binary(id),
       do: result(GitHub.attach_repositories(workspace, id, ids, actor: @owner), "attached")

  defp perform(%{"operation" => "attach_repositories"}, _), do: "invalid_input"

  defp perform(
         %{"operation" => "detach", "workspace_id" => workspace, "organization_id" => id},
         _
       )
       when is_binary(workspace) and is_binary(id),
       do: result(GitHub.detach(workspace, id, actor: @owner), "detached")

  defp perform(%{"operation" => "disconnect", "organization_id" => id}, _) when is_binary(id),
    do: result(GitHub.disconnect(id, actor: @owner), "disconnected")

  defp perform(_, _), do: "failed"

  defp save_client(session, id, secret, slug) do
    with {:ok, _} <- Lovelace.Owner.verify_session(session),
         {:ok, true} <- GitHub.save_client_credentials(id, secret, slug, actor: @owner) do
      :saved
    end
  end

  defp result({:ok, _}, success), do: success

  defp result({:error, reason}, _) when is_atom(reason),
    do: failure_category(%Error{reason: reason}) || "failed"

  defp result({:error, %Ash.Error.Invalid{errors: errors}}, _success),
    do: Enum.find_value(errors, "failed", &failure_category/1)

  defp result(_, _), do: "failed"

  defp failure_category(%Error{reason: reason}), do: Map.get(@failure_categories, reason)

  defp failure_category(%Ash.Error.Action.InvalidArgument{field: field})
       when field in [:client_id, :client_secret, :app_slug],
       do: "invalid_#{field}"

  defp failure_category(%Ash.Error.Changes.Required{field: field})
       when field in [:client_id, :client_secret, :app_slug],
       do: "invalid_#{field}"

  defp failure_category(%Ash.Error.Action.InvalidArgument{field: field})
       when field in [:connection_id, :organization_id, :workspace_id],
       do: "invalid_input"

  defp failure_category(_), do: nil

  defp destination(%{"operation" => operation, "workspace_id" => id}, result)
       when operation in ["attach", "attach_repositories", "detach"] do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> "/workspaces/" <> id <> "?github=" <> result
      _ -> "/connections/github?github=" <> result
    end
  end

  defp destination(_, result), do: "/connections/github?github=" <> result

  defp form_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "x-www-form-urlencoded", _}, Utils.content_type(type))
      _ -> false
    end
  end

  defp scrub(conn, params \\ %{}),
    do: %{conn | params: params, body_params: params, query_params: %{}, query_string: ""}

  defp redirect(conn, target) do
    conn
    |> scrub()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
    |> put_resp_header("location", target)
    |> send_resp(303, "")
    |> halt()
  end

  defp reject(conn, status) do
    conn
    |> scrub()
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "Unable to update GitHub connection")
    |> halt()
  end
end

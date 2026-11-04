defmodule LovelaceWeb.Plugs.GitHubCredentials do
  @moduledoc "Consumes owner-verified GitHub connection intent before instrumentation; credentials stay server-side."
  import Plug.Conn

  alias Lovelace.GitHub
  alias Lovelace.GitHub.{Auth, Error}
  alias LovelaceWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  @owner %{role: :local_owner}

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

      case Lovelace.Owner.verify_session(get_session(conn, :owner_session_token)) do
        {:ok, _session} ->
          result = perform(params, get_session(conn, :owner_session_token))
          redirect(conn, destination(params, result))

        _ ->
          redirect(conn, "/unlock")
      end
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

  defp perform(%{"operation" => "sign_in"}, session) do
    case Auth.begin(session) do
      :ok -> "pending"
      error -> result(error, "pending")
    end
  end

  defp perform(%{"operation" => "cancel_sign_in"}, session) do
    case Auth.cancel(session) do
      :ok -> "cancelled"
      {:error, :already_authorized} -> "authorized"
      error -> result(error, "cancelled")
    end
  end

  defp perform(%{"operation" => "discover", "connection_id" => id}, _) when is_binary(id),
    do: result(GitHub.discover(id, actor: @owner), "discovered")

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
         %{"operation" => "detach", "workspace_id" => workspace, "organization_id" => id},
         _
       )
       when is_binary(workspace) and is_binary(id),
       do: result(GitHub.detach(workspace, id, actor: @owner), "detached")

  defp perform(%{"operation" => "disconnect", "organization_id" => id}, _) when is_binary(id),
    do: result(GitHub.disconnect(id, actor: @owner), "disconnected")

  defp perform(_, _), do: "failed"

  defp result({:ok, _}, success), do: success

  defp result({:error, reason}, _) when is_atom(reason),
    do: failure_category(%Error{reason: reason}) || "failed"

  defp result({:error, %Ash.Error.Invalid{errors: errors}}, _success),
    do: Enum.find_value(errors, "failed", &failure_category/1)

  defp result(_, _), do: "failed"

  defp failure_category(%Error{reason: reason}) do
    case reason do
      :keychain -> "keychain_failed"
      :reconnect -> "access_failed"
      :rate_limited -> "rate_limited"
      :provider -> "provider_failed"
      :unavailable -> "unavailable"
      :configuration -> "configuration"
      _ -> nil
    end
  end

  defp failure_category(%Ash.Error.Action.InvalidArgument{field: field})
       when field in [:connection_id, :organization_id, :workspace_id],
       do: "invalid_input"

  defp failure_category(_), do: nil

  defp destination(%{"operation" => operation, "workspace_id" => id}, result)
       when operation in ["attach", "detach"] do
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

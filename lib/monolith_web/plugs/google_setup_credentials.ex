defmodule MonolithWeb.Plugs.GoogleSetupCredentials do
  @moduledoc "Consumes shared and onboarding Google secrets before logging, telemetry and parsers."
  import Plug.Conn

  alias Monolith.{Google, Onboarding, Owner}
  alias Monolith.Security.Vault
  alias MonolithWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  @onboarding_path ["onboarding", "credentials"]
  @connections_path ["connections", "google"]
  @owner %{role: :local_owner}
  @max_body 65_536

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      SensitivePath.matches?(conn, @onboarding_path) ->
        consume(conn, :onboarding)

      conn.method not in ["GET", "HEAD"] &&
          SensitivePath.matches?(conn, @connections_path) ->
        consume(conn, :connections)

      true ->
        conn
    end
  end

  defp consume(conn, destination) do
    conn = fetch_session(conn)

    cond do
      conn.query_string != "" -> reject(conn, 400)
      conn.method in ["GET", "HEAD"] -> redirect(conn, "/onboarding/client")
      conn.method != "POST" -> reject(conn, 400)
      true -> submit(conn, destination)
    end
  rescue
    _ -> reject(conn, 400)
  catch
    _, _ -> reject(conn, 400)
  end

  defp submit(conn, destination) do
    # Authenticate before reading credentials; verify again under the vault lease
    # before persisting. No browser-supplied actor is ever accepted.
    case Owner.verify_session(get_session(conn, :owner_session_token)) do
      {:ok, _} -> read_form(conn, destination)
      _ -> redirect(conn, "/unlock")
    end
  end

  defp read_form(conn, destination) do
    with true <- form_content_type?(conn),
         {:ok, body, conn} <-
           read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 5_000),
         true <- byte_size(body) <= @max_body do
      params = Query.decode(body)
      conn = scrub(conn, Map.take(params, ["_csrf_token"]))
      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
      token = get_session(conn, :owner_session_token)

      result = Vault.with_access(fn -> save_for_owner(token, params, destination) end)
      respond(conn, result, destination)
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

  defp save_for_owner(token, params, destination) do
    case Owner.verify_session(token) do
      {:ok, _} -> save(params, destination)
      _ -> :locked
    end
  end

  defp save(%{"client_id" => id, "client_secret" => secret}, destination)
       when is_binary(id) and is_binary(secret) do
    result =
      case destination do
        :onboarding -> Onboarding.save_credentials(id, secret, actor: @owner)
        :connections -> Google.save_client_credentials(id, secret, actor: @owner)
      end

    case result do
      {:ok, true} -> :saved
      {:error, :workspace_required} -> :workspace_required
      _ -> :failed
    end
  end

  defp save(_, _), do: :failed

  defp respond(conn, result, _) when result in [:locked, {:error, :locked}],
    do: redirect(conn, "/unlock")

  defp respond(conn, result, :onboarding) do
    case result do
      :saved -> redirect(conn, "/onboarding/connect")
      :workspace_required -> redirect(conn, "/onboarding/workspace")
      _ -> redirect(conn, "/onboarding/client?notice=save_failed")
    end
  end

  defp respond(conn, result, :connections) do
    notice = if result == :saved, do: "saved", else: "failed"
    redirect(conn, "/connections/google?google=" <> notice)
  end

  defp form_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "x-www-form-urlencoded", _}, Utils.content_type(type))
      _ -> false
    end
  end

  defp scrub(conn, params \\ %{}),
    do: %{conn | params: params, body_params: params, query_params: %{}, query_string: ""}

  defp private_response(conn) do
    conn
    |> scrub()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
  end

  defp redirect(conn, path) do
    conn
    |> private_response()
    |> put_resp_header("location", path)
    |> send_resp(303, "")
    |> halt()
  end

  defp reject(conn, status) do
    conn
    |> private_response()
    |> send_resp(status, "Unable to save Google client settings")
    |> halt()
  end
end

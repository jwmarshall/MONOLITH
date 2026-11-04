defmodule LovelaceWeb.Plugs.GoogleSetupCredentials do
  @moduledoc "Consumes Google setup secrets after session and before logging, telemetry and parsers."
  import Plug.Conn

  alias Lovelace.{Onboarding, Owner}
  alias Lovelace.Security.Vault
  alias LovelaceWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  @path ["onboarding", "credentials"]
  @owner %{role: :local_owner}
  @max_body 65_536

  def init(opts), do: opts

  def call(conn, _opts) do
    if SensitivePath.matches?(conn, @path), do: consume(conn), else: conn
  end

  defp consume(conn) do
    conn = fetch_session(conn)

    cond do
      conn.query_string != "" -> reject(conn, 400)
      conn.method in ["GET", "HEAD"] -> redirect(conn, "/onboarding/client")
      conn.method != "POST" -> reject(conn, 400)
      true -> submit(conn)
    end
  rescue
    _ -> reject(conn, 400)
  catch
    _, _ -> reject(conn, 400)
  end

  defp submit(conn) do
    # Authenticate before reading credentials; verify again under the vault lease
    # before persisting. No browser-supplied actor is ever accepted.
    case Owner.verify_session(get_session(conn, :owner_session_token)) do
      {:ok, _} -> read_form(conn)
      _ -> redirect(conn, "/unlock")
    end
  end

  defp read_form(conn) do
    with true <- form_content_type?(conn),
         {:ok, body, conn} <-
           read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 5_000),
         true <- byte_size(body) <= @max_body do
      params = Query.decode(body)
      conn = scrub(conn, Map.take(params, ["_csrf_token"]))
      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
      token = get_session(conn, :owner_session_token)

      result = Vault.with_access(fn -> save_for_owner(token, params) end)

      case result do
        :saved -> redirect(conn, "/onboarding/connect")
        :locked -> redirect(conn, "/unlock")
        _ -> redirect(conn, "/onboarding/client?notice=save_failed")
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

  defp save_for_owner(token, params) do
    case Owner.verify_session(token) do
      {:ok, _} -> save(params)
      _ -> :locked
    end
  end

  defp save(%{"client_id" => id, "client_secret" => secret})
       when is_binary(id) and is_binary(secret) do
    case Onboarding.save_credentials(id, secret, actor: @owner) do
      {:ok, true} -> :saved
      _ -> :failed
    end
  end

  defp save(_), do: :failed

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

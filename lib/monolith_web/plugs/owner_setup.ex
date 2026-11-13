defmodule MonolithWeb.Plugs.OwnerSetup do
  @moduledoc "Consumes pairing/password forms before logging, telemetry and parameter parsing."
  import Plug.Conn

  alias Monolith.Owner.{Actions, Throttle}
  alias Monolith.Security.Bootstrap
  alias MonolithWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  def init(options), do: options

  def call(conn, _options) do
    setup? =
      conn.path_info |> Enum.reject(&(&1 == "")) |> Enum.map(&URI.decode/1) |> List.first() ==
        "setup"

    if setup? and (conn.method not in ["GET", "HEAD"] or not safe_query?(conn.query_string)),
      do: consume(conn),
      else: conn
  end

  defp consume(conn) do
    conn = fetch_session(conn)

    with true <- conn.method == "POST" and conn.query_string == "",
         true <- form_content_type?(conn),
         {:ok, body, conn} <-
           read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5_000),
         true <- byte_size(body) <= 16_384 do
      params = Query.decode(body)
      conn = scrub(conn, Map.take(params, ["_csrf_token"]))
      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
      perform(conn, params)
    else
      _ -> reject(conn, 400)
    end
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError -> reject(conn, 403)
    _ -> reject(conn, 400)
  catch
    _, _ -> reject(conn, 400)
  end

  defp perform(conn, params) do
    cond do
      SensitivePath.matches?(conn, ["setup", "pair"]) -> pair(conn, params)
      SensitivePath.matches?(conn, ["setup", "password"]) -> configure(conn, params)
      true -> reject(conn, 404)
    end
  end

  defp pair(conn, params) do
    client = "setup:" <> to_string(:inet.ntoa(conn.remote_ip))

    with true <- Throttle.allow?(client),
         {:ok, capability} <- Bootstrap.pair(Map.get(params, "pairing_code")) do
      conn
      |> configure_session(renew: true)
      |> put_session(:bootstrap_capability, capability)
      |> redirect("/setup")
    else
      _ -> redirect(conn, "/setup?error=pairing")
    end
  end

  defp configure(conn, params) do
    result =
      Bootstrap.configure(
        get_session(conn, :bootstrap_capability),
        params["password"],
        params["password_confirmation"],
        params["acknowledge_recovery"] == "true"
      )

    case result do
      {:ok, token} ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:owner_session_token, token)
        |> put_session(
          :live_socket_id,
          Actions.topic(Actions.digest(token))
        )
        |> redirect("/onboarding")

      {:error, reason} when reason in [:password, :confirmation, :acknowledgement] ->
        redirect(conn, "/setup?error=#{reason}")

      _ ->
        redirect(conn, "/setup?error=setup")
    end
  end

  defp safe_query?(query),
    do:
      query in [
        "",
        "error=pairing",
        "error=password",
        "error=confirmation",
        "error=acknowledgement",
        "error=setup"
      ]

  defp form_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "x-www-form-urlencoded", _}, Utils.content_type(type))
      _ -> false
    end
  end

  defp scrub(conn, params \\ %{}),
    do: %{conn | params: params, body_params: params, query_params: %{}, query_string: ""}

  defp redirect(conn, path) do
    conn
    |> scrub()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
    |> put_resp_header("location", path)
    |> send_resp(303, "")
    |> halt()
  end

  defp reject(conn, status) do
    conn
    |> scrub()
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "Unable to configure MONOLITH. Return to /setup.")
    |> halt()
  end
end

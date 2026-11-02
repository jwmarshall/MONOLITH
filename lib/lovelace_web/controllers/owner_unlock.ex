defmodule LovelaceWeb.OwnerUnlock do
  @moduledoc """
  Early password POST boundary. Install after Plug.Session and before request logging,
  endpoint telemetry, and parsers. Passwords never enter the router's telemetry conn.
  """
  import Plug.Conn
  alias LovelaceWeb.OwnerController
  alias LovelaceWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.method == "POST" && SensitivePath.matches?(conn, ["unlock"]),
      do: unlock(conn),
      else: conn
  end

  defp unlock(conn) do
    conn = fetch_session(conn)

    with true <- form_content_type?(conn),
         true <- conn.query_string == "",
         {:ok, body, conn} <-
           read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5_000) do
      params = Query.decode(body)
      safe_params = Map.take(params, ["_csrf_token"])

      conn = %{
        conn
        | params: safe_params,
          body_params: safe_params,
          query_params: %{},
          query_string: ""
      }

      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
      # This dispatch has no router/request instrumentation. The controller immediately
      # removes the password from both parameter maps before invoking domain actions.
      conn = %{
        conn
        | body_params: Map.put(safe_params, "password", Map.get(params, "password", ""))
      }

      conn
      |> put_private(:owner_unlock_boundary, true)
      |> Phoenix.Controller.fetch_flash()
      |> Phoenix.Controller.put_secure_browser_headers(%{
        "content-security-policy" =>
          "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
      })
      |> Phoenix.Controller.put_format("html")
      |> Phoenix.Controller.put_view(html: LovelaceWeb.OwnerHTML)
      |> Phoenix.Controller.put_root_layout(html: {LovelaceWeb.Layouts, :root})
      |> OwnerController.call(:create)
      |> halt()
    else
      _ -> reject(conn, 400)
    end
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError -> reject(conn, 403)
    Plug.Conn.InvalidQueryError -> reject(conn, 400)
  end

  defp form_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [type] ->
        match?(
          {:ok, "application", "x-www-form-urlencoded", _},
          Utils.content_type(type)
        )

      _ ->
        false
    end
  end

  defp reject(conn, status) do
    conn = %{conn | params: %{}, body_params: %{}, query_params: %{}, query_string: ""}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "Unable to unlock")
    |> halt()
  end
end

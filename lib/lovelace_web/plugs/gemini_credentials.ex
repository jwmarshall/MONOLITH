defmodule LovelaceWeb.Plugs.GeminiCredentials do
  @moduledoc "Consumes API-key forms before Phoenix request instrumentation; never dispatches through LiveView."
  import Plug.Conn

  alias Lovelace.StageDesigner
  alias LovelaceWeb.Plugs.SensitivePath
  alias Plug.Conn.{Query, Utils}

  @owner %{role: :local_owner}

  def init(opts), do: opts

  def call(conn, _opts) do
    if SensitivePath.matches?(conn, ["connections", "gemini"]),
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
          result = perform(params)
          redirect(conn, "/?connections=gemini&gemini=" <> result)

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

  defp perform(%{"operation" => "save", "api_key" => key}) when is_binary(key) do
    case StageDesigner.save_gemini_key(key, actor: @owner) do
      {:ok, true} -> "saved"
      _ -> "failed"
    end
  end

  defp perform(%{"operation" => "remove"}) do
    case StageDesigner.remove_gemini_key(actor: @owner) do
      {:ok, true} -> "removed"
      _ -> "failed"
    end
  end

  defp perform(_), do: "failed"

  defp form_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [type] ->
        match?({:ok, "application", "x-www-form-urlencoded", _}, Utils.content_type(type))

      _ ->
        false
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
    |> send_resp(status, "Unable to update Gemini connection")
    |> halt()
  end
end
